/// Timezone-safe helpers. A "day" is the user's own LOCAL calendar day.
/// All arithmetic uses the DateTime constructor (not Duration math) so that
/// daylight-saving changes cannot shift a day boundary.
library;

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// The local day [n] days before [d] (DST-safe).
DateTime daysAgo(DateTime d, int n) => DateTime(d.year, d.month, d.day - n);

/// Monday of the week containing [d] (weeks start on Monday).
DateTime weekStart(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// UTC offset, in minutes, in force at the START of local day [d]. Sent with
/// each day so the server can sanity-check "today" without a timezone name.
int offsetMinutesFor(DateTime d) => startOfDay(d).timeZoneOffset.inMinutes;
