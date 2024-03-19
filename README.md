# Dart MPV JSONIPC

Dart implementation of MPV's IPC interface

Ported from [python-mpv-jsonipc](https://github.com/iwalton3/python-mpv-jsonipc)

## Basic Usage

```dart

// Launch MPV and connect to it.
final mpv = await MPV.launch(
  ipcSocket: '/tmp/mpv-socket',
  mpvArgs: {
    'force-window': 'yes',
  },
  logLevel: LogLevel.info,
  logHandler: (level, prefix, text) {
    print('mpv log: $level $prefix $text');
  },
  quitCallback: () {
    print('mpv exited');
  },
);

// or, connect to a running MPV instance connected to /tmp/mpv-socket.
final mpv = await MPV.connect(
  ipcSocket: '/tmp/mpv-socket',
);

// Read and set properties.
print(await mpv.getProperty('volume'));
await mpv.setProperty('volume', 50);

// You can also send commands.
mpv.command('loadfile', ['http://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_480p_surround-fix.avi']);

// Bind to a key press event.
mpv.onKey('p', () {
  print('Pressed P');
});

// Bind to an event.
mpv.onEvent('seek', (data) {
  print('Seeked');
});

// Observe property
final unobserveId = await mpv.observeProperty('time-pos', (name, data) {
  print('$name changed to $data');
});

// Unobserve property
await mpv.unobserveProperty(unobserveId);

// Or simply wait for the value to change once.
await mpv.waitForProperty('duration');
```
