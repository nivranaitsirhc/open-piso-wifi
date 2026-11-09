'use client';

import React from 'react';
import { AlertTriangle, Cpu } from 'lucide-react';
import { Input } from '@/components/ui/Input';

export interface GpioPinSelectorProps {
  backend: string;
  chip: string;
  coin: string;
  inhibit: string;
  onChange: (config: { backend: string; chip: string; coin: string; inhibit: string }) => void;
}

/**
 * Board-neutral GPIO configuration. A board's header layout is intentionally
 * not rendered here: physical header numbers and BCM values are not portable.
 */
export function GpioPinSelector({ backend, chip, coin, inhibit, onChange }: GpioPinSelectorProps) {
  const usesLines = backend === 'gpiod' || backend === 'auto';
  const identifierLabel = usesLines ? 'GPIO line offset' : 'GPIO identifier';

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div>
          <label className="block text-[11px] font-black uppercase text-black dark:text-white mb-1">Backend</label>
          <select
            value={backend}
            onChange={(event) => onChange({ backend: event.target.value, chip, coin, inhibit })}
            className="w-full h-10 px-3 rounded-xl bg-white dark:bg-[#1c241f] border-2 border-black dark:border-[#4a6052] text-xs text-black dark:text-white font-bold focus:outline-none shadow-neo-sm"
          >
            <option value="auto">Automatic (recommended)</option>
            <option value="gpiod">libgpiod character device</option>
            <option value="lgpio">gpiozero / lgpio (legacy BCM)</option>
          </select>
        </div>
        <div>
          <label className="block text-[11px] font-black uppercase text-black dark:text-white mb-1">GPIO chip</label>
          <Input value={chip} onChange={(event) => onChange({ backend, chip: event.target.value, coin, inhibit })} placeholder="/dev/gpiochip0" />
        </div>
        <div className="flex items-end text-[10px] font-bold text-neutral-600 dark:text-[#b7c6c2]">
          {backend === 'gpiod'
            ? 'Use gpioinfo on the target SBC to identify offsets.'
            : backend === 'lgpio'
              ? 'Legacy Raspberry Pi-compatible BCM identifiers.'
              : 'Non-Raspberry-Pi systems use libgpiod line offsets automatically.'}
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="p-3 rounded-xl bg-[#ffe17c] text-black border-2 border-black shadow-neo-sm">
          <label className="flex items-center gap-2 text-[11px] font-black uppercase mb-1">
            <span className="text-base">🪙</span> Coin input {identifierLabel}
          </label>
          <Input
            type="number"
            min={0}
            value={coin}
            onChange={(event) => onChange({ backend, chip, coin: event.target.value, inhibit })}
            placeholder={usesLines ? 'e.g. 12' : 'e.g. 4'}
            className="bg-white"
          />
        </div>
        <div className="p-3 rounded-xl bg-[#e9d5ff] text-purple-950 border-2 border-black shadow-neo-sm">
          <label className="flex items-center gap-2 text-[11px] font-black uppercase mb-1">
            <span className="text-base">🔒</span> Inhibit output {identifierLabel}
          </label>
          <Input
            type="number"
            min={0}
            value={inhibit}
            onChange={(event) => onChange({ backend, chip, coin, inhibit: event.target.value })}
            placeholder={usesLines ? 'e.g. 13' : 'e.g. 17'}
            className="bg-white"
          />
        </div>
      </div>

      <div className="flex items-start gap-2 p-3 rounded-xl bg-white dark:bg-[#111713] border-2 border-black dark:border-[#4a6052] text-[11px] font-semibold text-neutral-700 dark:text-[#b7c6c2]">
        <Cpu className="w-4 h-4 shrink-0 text-purple-600 dark:text-purple-400 mt-0.5" />
        <span>
          These values identify GPIO controller lines, not a universal physical header. Never copy a Raspberry Pi pin map to another SBC. Verify the chip, offset, signal voltage, and wiring on the target board before enabling the coin acceptor.
        </span>
      </div>
      {!coin.trim() || !inhibit.trim() ? (
        <div className="flex items-center gap-2 text-[11px] font-bold text-amber-700 dark:text-amber-300">
          <AlertTriangle className="w-3.5 h-3.5" /> Configure both GPIO identifiers before selecting the gpiod backend.
        </div>
      ) : null}
    </div>
  );
}
