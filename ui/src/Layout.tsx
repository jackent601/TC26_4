// App shell: a collapsible side nav (pages, then tenant, your name and theme at
// the bottom) and a title bar for the current page, with a DEMO pill on demo
// tenants (its tooltip explains the data is sample data and can be reset).
import { useState, type ReactNode } from "react";
import { NavLink, Outlet, useLocation } from "react-router";
import { BedIcon, GridIcon, HomeIcon, MonitorIcon, MoonIcon, PanelIcon, SunIcon } from "./icons";
import { useTenant } from "./tenant";
import { useTheme, type ThemeChoice } from "./theme";
import { useUser } from "./user";

const PAGES = [
  { to: "/", label: "Home", icon: <HomeIcon />, end: true },
  { to: "/availability", label: "Availability", icon: <GridIcon />, end: false },
];
// Pages that fill the window themselves (the grid scrolls inside).
const FILL = new Set(["/availability"]);

const NAV_KEY = "accomm.nav.collapsed";
const readCollapsed = () => {
  try {
    return localStorage.getItem(NAV_KEY) === "1";
  } catch {
    return false;
  }
};

export function Layout() {
  const { tenants, code, setCode, isDemo, error } = useTenant();
  const { name, setName } = useUser();
  const { theme, setTheme } = useTheme();
  const { pathname } = useLocation();
  const [collapsed, setCollapsedState] = useState(readCollapsed);
  const setCollapsed = (c: boolean) => {
    setCollapsedState(c);
    try {
      localStorage.setItem(NAV_KEY, c ? "1" : "0");
    } catch {
      // Storage blocked: lasts until the page is closed.
    }
  };

  const page = PAGES.find((p) => (p.end ? p.to === pathname : pathname.startsWith(p.to)));
  const themes: [ThemeChoice, string, ReactNode][] = [
    ["light", "Light", <SunIcon />],
    ["system", "System", <MonitorIcon />],
    ["dark", "Dark", <MoonIcon />],
  ];

  return (
    <div className={`shell${collapsed ? " collapsed" : ""}`}>
      <aside className="sidenav" aria-label="Main">
        <div className="brand">
          <span className="brand-mark"><BedIcon /></span>
          <span>Accommodation</span>
        </div>

        <nav className="nav-section">
          {PAGES.map((p) => (
            <NavLink key={p.to} to={p.to} end={p.end} className="nav-link" title={collapsed ? p.label : undefined}>
              {p.icon}
              <span className="label">{p.label}</span>
            </NavLink>
          ))}
        </nav>

        <div className="side-bottom">
          <span className="side-label">Tenant</span>
          <div className="seg-full" role="group" aria-label="Tenant">
            {tenants.map((t) => (
              <button key={t.code} type="button" aria-pressed={t.code === code} title={t.name}
                      onClick={() => t.code && setCode(t.code)}>
                {collapsed ? t.code?.charAt(0) : t.code}
              </button>
            ))}
          </div>

          <label className="side-field">
            <span className="side-label">Your name</span>
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder="For the audit log"
                   autoComplete="name" maxLength={100} />
          </label>

          <span className="side-label">Theme</span>
          <div className="seg-full" role="group" aria-label="Theme">
            {themes.map(([value, label, icon]) => (
              <button key={value} type="button" aria-pressed={theme === value} title={label} aria-label={label}
                      onClick={() => setTheme(value)}>
                {icon}
              </button>
            ))}
          </div>

          <button type="button" className="icon-btn collapse-btn" onClick={() => setCollapsed(!collapsed)}
                  aria-label={collapsed ? "Expand side bar" : "Collapse side bar"} aria-expanded={!collapsed}>
            <PanelIcon open={!collapsed} />
          </button>
        </div>
      </aside>

      <div className="content">
        <header className="topbar">
          <h1>{page?.label ?? "Not found"}</h1>
          {isDemo && (
            <span className="pill" role="status" title="Demo data: sample data only, and it can be reset at any time.">
              DEMO
            </span>
          )}
        </header>
        {error && <div className="demo-banner error">Could not load tenants: {error.message}</div>}

        <main className={`main${FILL.has(pathname) ? " fill" : ""}`}>
          <Outlet />
        </main>
      </div>
    </div>
  );
}
