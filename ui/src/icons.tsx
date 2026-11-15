// Small line icons (24px grid, stroke = currentColor), so they follow the theme.
import type { ReactNode } from "react";

function Icon({ children, size = 18 }: { children: ReactNode; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"
         strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

export const HomeIcon = () => <Icon><path d="M3 10.5 12 3l9 7.5" /><path d="M5 9.5V21h14V9.5" /><path d="M10 21v-6h4v6" /></Icon>;
export const GridIcon = () => <Icon><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18M8 4v16" /></Icon>;
export const BedIcon = () => <Icon size={18}><path d="M3 18V6" /><path d="M3 13h18v5" /><path d="M21 13a4 4 0 0 0-4-4h-6v4" /><circle cx="7" cy="10" r="2" /></Icon>;
export const SunIcon = () => <Icon size={15}><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></Icon>;
export const MoonIcon = () => <Icon size={15}><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z" /></Icon>;
export const MonitorIcon = () => <Icon size={15}><rect x="3" y="4" width="18" height="12" rx="2" /><path d="M8 20h8M12 16v4" /></Icon>;
export const PanelIcon = ({ open }: { open: boolean }) => (
  <Icon><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16" />{open ? <path d="m16 10-2 2 2 2" /> : <path d="m14 10 2 2-2 2" />}</Icon>
);
export const ListIcon = () => <Icon size={16}><path d="M8 6h13M8 12h13M8 18h13" /><circle cx="4" cy="6" r="1" /><circle cx="4" cy="12" r="1" /><circle cx="4" cy="18" r="1" /></Icon>;
export const SlidersIcon = () => <Icon size={16}><path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0" /><circle cx="16" cy="6" r="2" /><circle cx="10" cy="12" r="2" /><circle cx="18" cy="18" r="2" /></Icon>;
export const ExpandIcon = () => <Icon size={16}><path d="m7 9 5-5 5 5M7 15l5 5 5-5" /></Icon>;
export const CollapseIcon = () => <Icon size={16}><path d="m7 4 5 5 5-5M7 20l5-5 5 5" /></Icon>;
export const FilterIcon = () => <Icon size={16}><path d="M3 5h18l-7 8v6l-4 2v-8L3 5Z" /></Icon>;
export const ChartIcon = () => <Icon><path d="M4 20V10M10 20V4M16 20v-7M22 20H2" /></Icon>;
