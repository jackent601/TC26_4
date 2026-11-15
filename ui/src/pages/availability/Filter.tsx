// Location filter: tick the blocks to show, through a tree of sites, buildings
// and blocks. Ticking a parent ticks everything under it; a parent with some
// blocks ticked shows a half-ticked box. Display only: it narrows the rows
// shown, not what the database returns.
import { useEffect, useRef, type ReactNode } from "react";
import { levelPrefix } from "./look";
import type { LocationFilter } from "./settings";
import { NO_FILTER } from "./settings";
import type { LocationNode } from "./types";

const ABOVE_BLOCK = new Set(["Site", "Building"]);

// Every block under the given nodes (or in the whole tree).
function blocksUnder(nodes: LocationNode[]): LocationNode[] {
  return nodes.flatMap((n) => (n.level === "Block" ? [n] : ABOVE_BLOCK.has(n.level) ? blocksUnder(n.children) : []));
}

// The ticked blocks, or every block when there's no filter.
function selected(f: LocationFilter, roots: LocationNode[]): Set<string> {
  return new Set(f.blocks ?? blocksUnder(roots).map((b) => b.key));
}

// Keep only ticked blocks, with their sites and buildings above them. A site or
// building that loses some blocks is copied with `partial` and a bed count of
// what's left; untouched nodes are kept as they are.
export function pruneTree(roots: LocationNode[], f: LocationFilter): LocationNode[] {
  if (f.blocks === null) return roots;
  const keep = new Set(f.blocks);
  const prune = (n: LocationNode): LocationNode | null => {
    if (n.level === "Block") return keep.has(n.key) ? n : null;
    if (!ABOVE_BLOCK.has(n.level)) return n;
    const children = n.children.map(prune).filter((c): c is LocationNode => c !== null);
    if (children.length === 0) return null;
    const unchanged = children.length === n.children.length && children.every((c, i) => c === n.children[i]);
    if (unchanged) return n;
    return { ...n, children, partial: true, bedCount: children.reduce((s, c) => s + c.bedCount, 0) };
  };
  return roots.map(prune).filter((n): n is LocationNode => n !== null);
}

// "All locations", "Block B", "2 of 3 blocks" or "No locations" for the button.
export function filterLabel(f: LocationFilter, roots: LocationNode[]) {
  if (f.blocks === null) return "All locations";
  const all = blocksUnder(roots);
  const ticked = all.filter((b) => f.blocks!.includes(b.key));
  if (ticked.length === all.length) return "All locations";
  if (ticked.length === 0) return "No locations";
  if (ticked.length === 1) return ticked[0].name;
  return `${ticked.length} of ${all.length} blocks`;
}

export const isFiltered = (f: LocationFilter, roots: LocationNode[]) => filterLabel(f, roots) !== "All locations";

export function FilterPanel({ filter, roots, onFilter, close }: {
  filter: LocationFilter;
  roots: LocationNode[];
  onFilter: (f: LocationFilter) => void;
  close: () => void;
}) {
  const ticked = selected(filter, roots);
  const allBlocks = blocksUnder(roots);

  // Tick or untick a node: a block itself, or every block under a site/building.
  const toggle = (n: LocationNode) => {
    const blocks = n.level === "Block" ? [n] : blocksUnder(n.children);
    const allOn = blocks.every((b) => ticked.has(b.key));
    const next = new Set(ticked);
    blocks.forEach((b) => (allOn ? next.delete(b.key) : next.add(b.key)));
    // Everything ticked is the same as no filter, so new blocks show too.
    onFilter(next.size === allBlocks.length ? NO_FILTER : { blocks: [...next] });
  };

  const row = (n: LocationNode, depth: number): ReactNode => {
    if (n.level !== "Block" && !ABOVE_BLOCK.has(n.level)) return null;
    const blocks = n.level === "Block" ? [n] : blocksUnder(n.children);
    if (blocks.length === 0) return null;
    const on = blocks.filter((b) => ticked.has(b.key)).length;
    return (
      <li key={n.key}>
        <label style={{ paddingLeft: depth * 18 }} className={`lvl-${n.level.toLowerCase()}`}>
          <TriCheck checked={on === blocks.length} mixed={on > 0 && on < blocks.length} onChange={() => toggle(n)} />
          <span className="name">{n.name}</span>
          <span className="meta">{levelPrefix(n)}{n.bedCount} {n.bedCount === 1 ? "bed" : "beds"}</span>
        </label>
        {n.level !== "Block" && <ul>{n.children.map((c) => row(c, depth + 1))}</ul>}
      </li>
    );
  };

  return (
    <div className="filter-panel">
      <h2>Show</h2>
      <ul className="filter-tree">{roots.map((r) => row(r, 0))}</ul>
      <div className="apply">
        <div className="quick">
          <button type="button" className="tb-btn" disabled={filter.blocks === null} onClick={() => onFilter(NO_FILTER)}>All</button>
          <button type="button" className="tb-btn" disabled={ticked.size === 0} onClick={() => onFilter({ blocks: [] })}>None</button>
        </div>
        <button type="button" className="tb-btn primary" onClick={close}>Done</button>
      </div>
    </div>
  );
}

// A checkbox that can also show "some" (indeterminate), which has no HTML attribute.
function TriCheck({ checked, mixed, onChange }: { checked: boolean; mixed: boolean; onChange: () => void }) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = mixed;
  }, [mixed]);
  return <input ref={ref} type="checkbox" checked={checked} aria-checked={mixed ? "mixed" : checked} onChange={onChange} />;
}
