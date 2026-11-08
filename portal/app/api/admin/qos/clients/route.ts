import { NextRequest, NextResponse } from 'next/server';
import { prisma, ensureSqlitePragmas } from '@/lib/prisma';
import { getRouterDhcpLeases, getRouterQoSStatus, syncRouterQoS, type QoSConfig } from '@/lib/daemon';
import { normalizeMac } from '@/lib/arp';

export const dynamic = 'force-dynamic';

function parseMbps(value: unknown, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : fallback;
}

async function getDefaultQoS() {
  const settings = await prisma.setting.findMany({
    where: { key: { in: ['qos_default_download_mbps', 'qos_default_upload_mbps', 'speed_limit', 'custom_down_mbps', 'custom_up_mbps'] } },
  });
  const values = Object.fromEntries(settings.map((setting) => [setting.key, setting.value]));

  let fallbackDown = 25;
  let fallbackUp = 10;
  if (values.speed_limit === '50mbps') {
    fallbackDown = 50;
    fallbackUp = 20;
  } else if (values.speed_limit === '100mbps') {
    fallbackDown = 100;
    fallbackUp = 50;
  } else if (values.speed_limit === 'unlimited') {
    fallbackDown = 0;
    fallbackUp = 0;
  } else if (values.speed_limit === 'custom') {
    fallbackDown = parseMbps(values.custom_down_mbps, 25);
    fallbackUp = parseMbps(values.custom_up_mbps, 10);
  }

  return {
    downloadMbps: parseMbps(values.qos_default_download_mbps, fallbackDown),
    uploadMbps: parseMbps(values.qos_default_upload_mbps, fallbackUp),
  };
}

async function buildQoSConfig(): Promise<{ config: QoSConfig; clients: any[]; status: any }> {
  const defaults = await getDefaultQoS();
  const overrides = await prisma.clientBandwidthLimit.findMany({ orderBy: { updatedAt: 'desc' } });
  const leases = await getRouterDhcpLeases().catch(() => []);
  const overrideMap = new Map(overrides.map((rule) => [rule.macAddress.toLowerCase(), rule]));
  const leaseMap = new Map(leases.map((lease) => [lease.mac.toLowerCase(), lease]));

  const clients = leases.map((lease) => {
    const override = overrideMap.get(lease.mac.toLowerCase());
    return {
      macAddress: lease.mac,
      ipAddress: lease.ip,
      hostname: lease.hostname,
      downloadMbps: override?.downloadMbps ?? defaults.downloadMbps,
      uploadMbps: override?.uploadMbps ?? defaults.uploadMbps,
      enabled: override?.enabled ?? true,
      hasOverride: Boolean(override),
      isOverride: Boolean(override),
    };
  });

  // Keep offline overrides in the daemon's persisted configuration. They will
  // become active automatically when the client receives a new IPv4 lease.
  for (const override of overrides) {
    if (!leaseMap.has(override.macAddress.toLowerCase())) {
      clients.push({
        macAddress: override.macAddress,
        ipAddress: '',
        hostname: undefined,
        downloadMbps: override.downloadMbps,
        uploadMbps: override.uploadMbps,
        enabled: override.enabled,
        hasOverride: true,
        isOverride: true,
      });
    }
  }

  const config: QoSConfig = {
    defaultDownloadMbps: defaults.downloadMbps,
    defaultUploadMbps: defaults.uploadMbps,
    clients: clients.map((client) => ({
      macAddress: client.macAddress,
      ipAddress: client.ipAddress,
      downloadMbps: client.downloadMbps,
      uploadMbps: client.uploadMbps,
      enabled: client.enabled,
      isOverride: client.isOverride,
    })),
  };

  const status = await getRouterQoSStatus().catch(() => null);
  return { config, clients, status };
}

async function syncCurrentQoS() {
  const { config } = await buildQoSConfig();
  return syncRouterQoS(config);
}

export async function GET() {
  await ensureSqlitePragmas();

  try {
    const { config, clients, status } = await buildQoSConfig();
    return NextResponse.json({
      defaultDownloadMbps: config.defaultDownloadMbps,
      defaultUploadMbps: config.defaultUploadMbps,
      clients,
      status,
    });
  } catch (error: any) {
    return NextResponse.json({ error: error.message || 'Failed to fetch QoS configuration' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  await ensureSqlitePragmas();

  try {
    const body = await request.json();
    const rawMac = body.macAddress || body.mac;

    if (rawMac) {
      const macAddress = normalizeMac(String(rawMac));
      const downloadMbps = parseMbps(body.downloadMbps, -1);
      const uploadMbps = parseMbps(body.uploadMbps, -1);
      if (macAddress.length !== 17 || downloadMbps < 1 || uploadMbps < 1) {
        return NextResponse.json({ error: 'Valid MAC address and positive IPv4 download/upload limits are required' }, { status: 400 });
      }

      await prisma.clientBandwidthLimit.upsert({
        where: { macAddress },
        update: { downloadMbps, uploadMbps, enabled: body.enabled !== false },
        create: { macAddress, downloadMbps, uploadMbps, enabled: body.enabled !== false },
      });
    } else {
      const downloadMbps = parseMbps(body.defaultDownloadMbps, -1);
      const uploadMbps = parseMbps(body.defaultUploadMbps, -1);
      if (downloadMbps < 0 || uploadMbps < 0) {
        return NextResponse.json({ error: 'Default IPv4 download/upload limits must be zero or greater' }, { status: 400 });
      }
      await prisma.setting.upsert({ where: { key: 'qos_default_download_mbps' }, update: { value: String(downloadMbps) }, create: { key: 'qos_default_download_mbps', value: String(downloadMbps) } });
      await prisma.setting.upsert({ where: { key: 'qos_default_upload_mbps' }, update: { value: String(uploadMbps) }, create: { key: 'qos_default_upload_mbps', value: String(uploadMbps) } });
    }

    const sync = await syncCurrentQoS();
    if (!sync.success) {
      return NextResponse.json({ error: sync.error || 'QoS saved but daemon synchronization failed' }, { status: 502 });
    }
    return NextResponse.json({ success: true, message: rawMac ? 'Client bandwidth override saved' : 'Default per-client bandwidth saved' });
  } catch (error: any) {
    return NextResponse.json({ error: error.message || 'Failed to save QoS configuration' }, { status: 500 });
  }
}

export async function DELETE(request: NextRequest) {
  await ensureSqlitePragmas();

  try {
    const rawMac = new URL(request.url).searchParams.get('mac') || '';
    const macAddress = normalizeMac(rawMac);
    if (macAddress.length !== 17) {
      return NextResponse.json({ error: 'Valid MAC address required' }, { status: 400 });
    }
    await prisma.clientBandwidthLimit.deleteMany({ where: { macAddress } });
    const sync = await syncCurrentQoS();
    if (!sync.success) {
      return NextResponse.json({ error: sync.error || 'Override removed but daemon synchronization failed' }, { status: 502 });
    }
    return NextResponse.json({ success: true, message: 'Client override removed; default bandwidth restored' });
  } catch (error: any) {
    return NextResponse.json({ error: error.message || 'Failed to remove QoS override' }, { status: 500 });
  }
}
