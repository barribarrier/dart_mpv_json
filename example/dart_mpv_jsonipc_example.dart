import 'dart:async';

import 'package:dart_mpv_jsonipc/dart_mpv_jsonipc.dart';

Future<void> main() async {
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

  mpv.command('loadfile', [
    'http://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_480p_surround-fix.avi'
  ]);

  mpv.onKey('p', () {
    print('P');
  });

  mpv.onEvent('seek', (data) {
    print('Seeked');
  });

  mpv.observeProperty('time-pos', (name, data) {
    print('$name changed to $data');
  });

  print((await mpv.getProperty<double>('volume')));
  await mpv.setProperty('volume', 50);
  print((await mpv.getProperty<double>('volume')));
}
