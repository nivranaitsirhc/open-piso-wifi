'use client';

import { useEffect, useRef, useState } from 'react';
import useSWR from 'swr';
import { Gauge, Save, Trash2, Zap, CheckCircle2, AlertCircle } from 'lucide-react';
import { Card, CardHeader, CardTitle } from '@/components/ui/Card';
import { Input } from '@/components/ui/Input';
import { Button } from '@/components/ui/Button';

const fetcher = (url: string) => fetch(url).then((res) => res.json());

interface QoSClient {
  macAddress: string;
  ipAddress?: string;
  hostname?: string;
  downloadMbps: number;
  uploadMbps: number;
  enabled: boolean;
  hasOverride: boolean;
}

interface QoSData {
  defaultDownloadMbps: number;
  defaultUploadMbps: number;
  clients: QoSClient[];
  status?: {
    active: boolean;
    lanInterface: string;
    wanInterface: string;
    clientCount?: number;
  } | null;
}

export function GatewayQoSCard() {
  const { data, mutate, isLoading } = useSWR<QoSData>('/api/admin/qos/clients', fetcher, {
    refreshInterval: 10000,
  });
  const [defaultDownload, setDefaultDownload] = useState('25');
  const [defaultUpload, setDefaultUpload] = useState('10');
  const [selectedMac, setSelectedMac] = useState('');
  const [clientDownload, setClientDownload] = useState('');
  const [clientUpload, setClientUpload] = useState('');
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);
  const [saving, setSaving] = useState(false);
  const defaultsInitialized = useRef(false);

  useEffect(() => {
    if (data && !defaultsInitialized.current) {
      setDefaultDownload(String(data.defaultDownloadMbps));
      setDefaultUpload(String(data.defaultUploadMbps));
      defaultsInitialized.current = true;
    }
  }, [data?.defaultDownloadMbps, data?.defaultUploadMbps]);

  const selectClient = (mac: string) => {
    const client = data?.clients.find((item) => item.macAddress === mac);
    setSelectedMac(mac);
    setClientDownload(client?.hasOverride ? String(client.downloadMbps) : '');
    setClientUpload(client?.hasOverride ? String(client.uploadMbps) : '');
    setMessage(null);
  };

  const saveDefault = async () => {
    setSaving(true);
    setMessage(null);
    try {
      const res = await fetch('/api/admin/qos/clients', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ defaultDownloadMbps: Number(defaultDownload), defaultUploadMbps: Number(defaultUpload) }),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || 'Failed to save default bandwidth');
      setMessage({ type: 'success', text: 'Default per-client bandwidth applied.' });
      mutate();
    } catch (error: any) {
      setMessage({ type: 'error', text: error.message || 'Failed to save default bandwidth' });
    } finally {
      setSaving(false);
    }
  };

  const saveOverride = async () => {
    if (!selectedMac) return;
    setSaving(true);
    setMessage(null);
    try {
      const res = await fetch('/api/admin/qos/clients', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ macAddress: selectedMac, downloadMbps: Number(clientDownload), uploadMbps: Number(clientUpload) }),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || 'Failed to save client override');
      setMessage({ type: 'success', text: `Bandwidth override saved for ${selectedMac}.` });
      mutate();
    } catch (error: any) {
      setMessage({ type: 'error', text: error.message || 'Failed to save client override' });
    } finally {
      setSaving(false);
    }
  };

  const removeOverride = async () => {
    if (!selectedMac) return;
    setSaving(true);
    setMessage(null);
    try {
      const res = await fetch(`/api/admin/qos/clients?mac=${encodeURIComponent(selectedMac)}`, { method: 'DELETE' });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || 'Failed to remove client override');
      setClientDownload('');
      setClientUpload('');
      setMessage({ type: 'success', text: 'Client override removed; default restored.' });
      mutate();
    } catch (error: any) {
      setMessage({ type: 'error', text: error.message || 'Failed to remove client override' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Card className="border-2 border-black dark:border-[#4a6052] shadow-neo space-y-5">
      <CardHeader className="flex flex-row items-center justify-between pb-2 gap-3">
        <div className="flex items-center gap-2.5">
          <div className="p-2 rounded-xl bg-[#4ade80] text-black border-2 border-black shadow-neo-sm">
            <Gauge className="w-5 h-5 stroke-[2.5]" />
          </div>
          <div>
            <CardTitle>Gateway Bandwidth & QoS</CardTitle>
            <p className="text-xs text-neutral-600 dark:text-[#b7c6c2]">
              Independent IPv4 download and upload limits for every client
            </p>
          </div>
        </div>
        {data?.status && (
          <span className={`text-[10px] font-black px-2 py-1 rounded border-2 border-black ${data.status.active ? 'bg-[#4ade80]' : 'bg-[#ffe17c]'}`}>
            {data.status.active ? 'QoS Active' : 'QoS Ready'}
          </span>
        )}
      </CardHeader>

      {message && (
        <div className={`flex items-center gap-2 p-3 rounded-xl border-2 border-black text-xs font-bold ${message.type === 'success' ? 'bg-[#4ade80]' : 'bg-[#ff5f57]'}`}>
          {message.type === 'success' ? <CheckCircle2 className="w-4 h-4" /> : <AlertCircle className="w-4 h-4" />}
          <span>{message.text}</span>
        </div>
      )}

      <div className="p-4 rounded-xl bg-[#f8f6ee] dark:bg-[#111713] border-2 border-black dark:border-[#4a6052] space-y-3">
        <div>
          <h3 className="text-xs font-black uppercase">Default Per-Client Bandwidth</h3>
          <p className="text-[10px] font-bold text-neutral-600 dark:text-[#b7c6c2]">Used by clients without an override. Zero means unlimited.</p>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end">
          <label className="text-[10px] font-black">Download Mbps<Input type="number" min={0} value={defaultDownload} onChange={(e) => setDefaultDownload(e.target.value)} /></label>
          <label className="text-[10px] font-black">Upload Mbps<Input type="number" min={0} value={defaultUpload} onChange={(e) => setDefaultUpload(e.target.value)} /></label>
          <Button type="button" onClick={saveDefault} isLoading={saving} className="gap-1.5">
            <Save className="w-4 h-4" /> Apply Default
          </Button>
        </div>
      </div>

      <div className="p-4 rounded-xl bg-[#f8f6ee] dark:bg-[#111713] border-2 border-black dark:border-[#4a6052] space-y-3">
        <div>
          <h3 className="text-xs font-black uppercase">Per-Client Override</h3>
          <p className="text-[10px] font-bold text-neutral-600 dark:text-[#b7c6c2]">IPv4 clients are matched by MAC and current DHCP address.</p>
        </div>
        <select value={selectedMac} onChange={(e) => selectClient(e.target.value)} className="w-full h-10 px-3 rounded-xl bg-white dark:bg-[#1c241f] border-2 border-black text-xs font-bold">
          <option value="">Select a connected or saved client</option>
          {(data?.clients || []).map((client) => (
            <option key={client.macAddress} value={client.macAddress}>
              {client.hostname || 'Client'} • {client.ipAddress || 'offline'} • {client.macAddress}{client.hasOverride ? ' • override' : ''}
            </option>
          ))}
        </select>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end">
          <label className="text-[10px] font-black">Download Mbps<Input type="number" min={1} value={clientDownload} onChange={(e) => setClientDownload(e.target.value)} disabled={!selectedMac} /></label>
          <label className="text-[10px] font-black">Upload Mbps<Input type="number" min={1} value={clientUpload} onChange={(e) => setClientUpload(e.target.value)} disabled={!selectedMac} /></label>
          <div className="flex gap-2">
            <Button type="button" onClick={saveOverride} isLoading={saving} disabled={!selectedMac} className="gap-1.5 flex-1">
              <Zap className="w-4 h-4" /> Apply Override
            </Button>
            <Button type="button" variant="outline" onClick={removeOverride} isLoading={saving} disabled={!selectedMac} title="Remove override">
              <Trash2 className="w-4 h-4" />
            </Button>
          </div>
        </div>
      </div>

      <p className="text-[10px] font-bold text-neutral-600 dark:text-[#b7c6c2]">
        Interfaces: {data?.status?.lanInterface || 'detecting LAN'} → {data?.status?.wanInterface || 'detecting WAN'} · {isLoading ? 'Loading clients…' : `${data?.clients?.length || 0} clients tracked`}
      </p>
    </Card>
  );
}
