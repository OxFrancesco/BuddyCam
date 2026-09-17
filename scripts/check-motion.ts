// Run on a clip with camera movement. A stationary subject can legitimately repeat.
const [file, crop] = process.argv.slice(2);
if (!file) throw new Error('Usage: bun scripts/check-motion.ts FILE [width:height:x:y]');
// Small overlays lose sensor noise when resized. -55 dB flags still subjects as frozen.
// -70 dB still catches the original repeating-frame clip without that false positive.
const filter = `${crop ? `crop=${crop},` : ''}freezedetect=n=-70dB:d=0.2`;
const child = Bun.spawn(['ffmpeg', '-hide_banner', '-i', file, '-vf', filter, '-an', '-f', 'null', '-'], {stdout:'ignore', stderr:'pipe'});
const log = await new Response(child.stderr).text();
if (await child.exited) throw new Error(log);
let start = 0;
const freezes: {start: number; duration: number}[] = [];
for (const line of log.split('\n')) {
  const s = line.match(/freeze_start: ([\d.]+)/);
  if (s) start = Number(s[1]);
  const d = line.match(/freeze_duration: ([\d.]+)/);
  if (d && start >= 1) freezes.push({start, duration:Number(d[1])});
}
console.log(JSON.stringify({file, excludedStartupSeconds:1, freezes, pass:freezes.length === 0},null,2));
process.exitCode = freezes.length ? 1 : 0;
