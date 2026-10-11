// Calendar validation shared by local and offset input; never rely on Date normalization.
export function validCalendarFields(year: number, month: number, day: number,
  hour: number, minute: number, second: number = 0): boolean {
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days: Array<number> = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year >= 1 && year <= 9999 && month >= 1 && month <= 12 && day >= 1 &&
    day <= days[month - 1] && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 && second >= 0 && second <= 59;
}
export function parseExplicitTime(value: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (match === null) { throw new Error('请输入明确日期、时刻和时区'); }
  if (!validCalendarFields(Number(match[1]), Number(match[2]), Number(match[3]),
    Number(match[4]), Number(match[5]), Number(match[6] ?? '0'))) { throw new Error('日期或时间不存在，请重新选择'); }
  const offset = match[7];
  if (offset !== 'Z' && (Number(offset.slice(1,3)) > 23 || Number(offset.slice(4,6)) > 59)) { throw new Error('时区偏移无效'); }
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) { throw new Error('日期或时间不存在，请重新选择'); }
  return timestamp;
}
