// Preloaded into the streaming server (node -r shell-watchdog.js server.js).
// Exits the server if the Stremio Community app that started it is gone,
// e.g. after a crash, so no orphaned server keeps port 11470 busy.
const pid = parseInt(process.env.STREMIO_SHELL_PID || '0', 10);
if (pid > 0) {
  setInterval(() => {
    try {
      process.kill(pid, 0);
    } catch (e) {
      process.exit(0);
    }
  }, 2000).unref();
}
