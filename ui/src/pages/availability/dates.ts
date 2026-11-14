// Dates on the page are calendar days, held as ISO strings ("2026-11-16") as the
// API sends them. A night is the date it starts; end dates are departure days
// (exclusive), as in the database.
import { addDays, differenceInCalendarDays, format, parseISO, startOfWeek } from "date-fns";

export const iso = (d: Date) => format(d, "yyyy-MM-dd");
export const parse = (s: string) => parseISO(s);

// Monday of the week containing d.
export const mondayOf = (d: Date) => startOfWeek(d, { weekStartsOn: 1 });

// Default first week: the Monday two weeks ago, so recent stays are in view
// (the demo data starts there too).
export const defaultStart = () => iso(mondayOf(addDays(new Date(), -14)));

export const addDaysIso = (s: string, n: number) => iso(addDays(parseISO(s), n));

// Nights from `start` to `s` (negative if before).
export const dayIndex = (start: string, s: string) => differenceInCalendarDays(parseISO(s), parseISO(start));

export const ddmm = (s: string) => format(parseISO(s), "dd/MM");
export const dayLong = (s: string) => format(parseISO(s), "EEE dd/MM");
export const dayLongYear = (s: string) => format(parseISO(s), "EEE dd/MM yyyy");
