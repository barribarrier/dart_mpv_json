import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';

enum LogLevel {
  no,
  fatal,
  error,
  warn,
  info,
  status,
  v,
  debug,
  trace,
}

typedef RequestID = int;
typedef ObserverID = int;
typedef Event = String;
typedef Property = String;
typedef EventListenerFunction = void Function(dynamic data);
typedef PropertyObserverFunction = void Function(Property name, dynamic data);
typedef UnsubscribeFunction = void Function();
typedef LogHandlerFunction = Function(String level, String prefix, String text);

const commandTimeout = 120;

/// An error originating from MPV or due to a problem with MPV.
class MPVError extends Error {
  final String message;

  MPVError(this.message);

  @override
  String toString() {
    return "MPVError: ${Error.safeToString(message)}";
  }
}

abstract class _Socket {
  final String ipcSocket;
  final Function(dynamic data) callback;
  final Function? quitCallback;
  Socket? socket;

  _Socket({
    required this.ipcSocket,
    required this.callback,
    this.quitCallback,
  });

  /// Process socket events.
  Future<void> start();

  /// Terminate the socket connection.
  void stop();

  /// Send [data] to the socket, encoded as JSON.
  void send(Object data);
}

/// Wraps a Unix/Linux socket in a high-level interface. (Internal)
/// Data is automatically encoded and decoded as JSON. The callback
/// function will be called for each inbound message.
class _UnixSocket extends _Socket {
  _UnixSocket({
    /// Path to the socket.
    required String ipcSocket,

    /// Function for recieving events.
    required Function(dynamic data) callback,

    /// Called when the socket connection dies.
    Function? quitCallback,
  }) : super(
          ipcSocket: ipcSocket,
          callback: callback,
          quitCallback: quitCallback,
        );

  @override
  Future<void> start() async {
    socket = await Socket.connect(
      InternetAddress(ipcSocket, type: InternetAddressType.unix),
      0,
      timeout: Duration(seconds: 1),
    );

    List<int> buffer = [];
    socket?.listen(
      (event) {
        List<int> data = event.toList();

        while (true) {
          if (data.isEmpty) {
            break;
          }

          final newlineIndex = data.indexOf('\n'.codeUnitAt(0));

          if (newlineIndex == -1) {
            buffer.addAll(data);
            break;
          }

          final tail = data.getRange(0, newlineIndex).toList();
          final fullMsg = buffer + tail;

          data.removeRange(0, newlineIndex + 1);
          buffer.clear();

          final json = jsonDecode(String.fromCharCodes(fullMsg));
          callback(json);
        }
      },
      onDone: () {
        quitCallback?.call();
      },
      onError: (e) {
        quitCallback?.call();
      },
    );
  }

  @override
  void stop() {
    socket?.destroy();
  }

  @override
  void send(Object data) {
    if (socket == null) {
      throw SocketException('Socket is not ready');
    }
    socket?.write('${jsonEncode(data)}\n');
  }
}

/// Manages an MPV process, ensuring the socket or pipe is available. (Internal)
class _MPVProcess {
  /// Path to the Unix/Linux socket or name of the Windows pipe.
  final String ipcSocket;

  /// Path to mpv. If left unset it tries the one in the PATH.
  final String? mpvLocation;

  /// Arguments to pass to MPV.
  final Map<String, String>? mpvArgs;

  Process? _process;

  _MPVProcess({
    required this.ipcSocket,
    this.mpvLocation,
    this.mpvArgs,
  });

  Future<void> start() async {
    // TODO: Windows
    final path = mpvLocation ?? 'mpv';

    final Map<String, String> args = mpvArgs ?? {};
    args['idle'] = 'yes';
    args['input-ipc-server'] = ipcSocket;
    args['input-terminal'] = 'no';
    args['terminal'] = 'no';

    try {
      await File(ipcSocket).delete();
    } catch (_) {}

    final process = await Process.start(
      path,
      args.entries.expand((e) => ['--${e.key}=${e.value}']).toList(),
      mode: ProcessStartMode.normal,
    );
    int? exitCode;
    process.exitCode.then((value) {
      exitCode = value;
    });
    _process = process;
    bool ipcExists = false;
    for (var i = 0; i < 100; i++) {
      await Future.delayed(Duration(milliseconds: 100));
      if (await File(ipcSocket).exists()) {
        ipcExists = true;
        break;
      }
      if (exitCode != null) {
        process.kill(ProcessSignal.sigterm);
        throw MPVError('MPV failed with returncode $exitCode.');
      }
    }
    if (!ipcExists) {
      process.kill(ProcessSignal.sigterm);
      throw MPVError('MPV start timed out.');
    }
  }

  /// Terminate the process.
  Future<void> stop() async {
    _process?.kill(ProcessSignal.sigterm);

    try {
      await File(ipcSocket).delete();
    } catch (_) {}
  }
}

/// Low-level interface to MPV. Does NOT manage an mpv process. (Internal)
class _MPVInter {
  /// Path to the Unix/Linux socket or name of the Windows pipe.
  final String ipcSocket;

  /// Function for recieving events.
  final Function(Event name, dynamic data) callback;

  /// Called when the socket connection to MPV dies.
  final Function? quitCallback;

  late _Socket _socket;
  RequestID _requestId = 1;
  final Map<RequestID, Completer> _ipcRequests = {};

  _MPVInter({
    required this.ipcSocket,
    required this.callback,
    this.quitCallback,
  });

  Future<void> start() async {
    // TODO: Windows
    _socket = _UnixSocket(
      ipcSocket: ipcSocket,
      callback: eventCallback,
      quitCallback: quitCallback,
    );
    await _socket.start();
  }

  /// Terminate the underlying connection.
  void stop() {
    _socket.stop();
  }

  /// Internal callback for recieving events from MPV.
  void eventCallback(dynamic data) {
    final dataMap = data as Map;
    if (dataMap.containsKey('request_id')) {
      final ipcRequest = _ipcRequests[dataMap['request_id']];
      if (ipcRequest != null && !ipcRequest.isCompleted) {
        if (dataMap['error'] != 'success') {
          ipcRequest.completeError(MPVError(dataMap['error']));
        } else {
          ipcRequest.complete(dataMap['data']);
        }
        _ipcRequests.remove(ipcRequest);
      }
    } else if (dataMap.containsKey('event')) {
      callback(data['event'], data);
    }
  }

  /// Issue a command to MPV.
  ///
  /// Throws [TimeoutException] if timeout of 120 seconds is reached.
  Future<T> command<T>(String command, [List args = const []]) {
    final commandId = _requestId++;
    final commandMap = {
      'command': [command, ...args],
      'request_id': commandId,
    };
    final completer = Completer<T>();

    try {
      _socket.send(commandMap);
      _ipcRequests[commandId] = completer;
    } catch (e) {
      completer.completeError(e);
    }

    return completer.future.timeout(
      Duration(seconds: commandTimeout),
      onTimeout: () {
        throw TimeoutException('No response from MPV.');
      },
    );
  }
}

class MPV {
  late final String _ipcSocket;
  late final LogLevel _logLevel;
  late final LogHandlerFunction? _logHandler;
  late final Function? _quitCallback;

  late final _MPVInter _mpvInter;
  late final _MPVProcess? _mpvProcess;

  // Property observers
  ObserverID _propertyObserverId = 1;
  final Map<ObserverID, PropertyObserverFunction> _propertyBindings = {};

  // Event listeners
  final Map<Event, List<EventListenerFunction>> _eventBindings = {};

  // Key bindings
  int _keyBindingId = 1;
  final Map<String, Function> _keyBindings = {};

  MPV._internal({
    String? ipcSocket,
    bool startMPV = false,
    String? mpvLocation,
    Map<String, String>? mpvArgs,
    LogLevel logLevel = LogLevel.status,
    LogHandlerFunction? logHandler,
    Function? quitCallback,
  })  : _logLevel = logLevel,
        _logHandler = logHandler,
        _quitCallback = quitCallback {
    if (ipcSocket == null) {
      final randFile = 'mpv${Random().nextInt(pow(2, 32) as int)}';
      if (Platform.isWindows) {
        // TODO:
        _ipcSocket = '';
      } else {
        _ipcSocket = '/tmp/$randFile';
      }
    } else {
      _ipcSocket = ipcSocket;
    }

    if (startMPV) {
      _mpvProcess = _MPVProcess(
        ipcSocket: _ipcSocket,
        mpvLocation: mpvLocation,
        mpvArgs: mpvArgs,
      );
    }

    _mpvInter = _MPVInter(
      ipcSocket: _ipcSocket,
      callback: (name, data) {
        _notifyEventListeners(name, data);
      },
      quitCallback: () {
        _quitCallback?.call();
        terminate();
      },
    );
  }

  Future<void> _initialize() async {
    await _mpvProcess?.start();
    await _mpvInter.start();

    if (_logHandler != null && _logLevel != LogLevel.status) {
      await command('request_log_messages', [_logLevel.name]);
      onEvent('log-message', (data) {
        final dataMap = data as Map;
        _logHandler?.call(
          dataMap['level'],
          dataMap['prefix'],
          '${dataMap['text']}'.trim(),
        );
      });
    }

    onEvent('property-change', (data) {
      final dataMap = data as Map;
      _propertyBindings[dataMap['id']]?.call(
        dataMap['name'],
        dataMap['data'],
      );
    });

    onEvent('client-message', (data) {
      final dataMap = data as Map;
      final args = dataMap['args'] as List;
      if (args.length == 2 && args[0] == 'custom-bind') {
        _keyBindings[args[1]]?.call();
      }
    });
  }

  static Future<MPV> connect({
    /// Path to the Unix/Linux socket or name of Windows pipe. (Default: Random Temp File)
    String? ipcSocket,

    /// Level for log messages.
    LogLevel logLevel = LogLevel.status,

    /// Handler for log events.
    LogHandlerFunction? logHandler,

    /// Called when the socket connection to MPV dies.
    Function? quitCallback,
  }) async {
    final mpv = MPV._internal(
      ipcSocket: ipcSocket,
      startMPV: false,
      logLevel: logLevel,
      logHandler: logHandler,
      quitCallback: quitCallback,
    );
    await mpv._initialize();

    return mpv;
  }

  static Future<MPV> launch({
    /// Path to the Unix/Linux socket or name of Windows pipe. (Default: Random Temp File)
    String? ipcSocket,

    /// Location of MPV executable. (Default: Use MPV in PATH)
    String? mpvLocation,

    /// Arguments to pass to MPV.
    Map<String, String>? mpvArgs,

    /// Level for log messages.
    LogLevel logLevel = LogLevel.status,

    /// Handler for log events.
    LogHandlerFunction? logHandler,

    /// Called when the socket connection to MPV dies.
    Function? quitCallback,
  }) async {
    final mpv = MPV._internal(
      ipcSocket: ipcSocket,
      startMPV: true,
      mpvLocation: mpvLocation,
      mpvArgs: mpvArgs,
      logLevel: logLevel,
      logHandler: logHandler,
      quitCallback: quitCallback,
    );
    await mpv._initialize();

    return mpv;
  }

  /// Bind a callback to an MPV event.
  UnsubscribeFunction onEvent(
    Event name,
    EventListenerFunction listener,
  ) {
    if (_eventBindings[name] == null) {
      _eventBindings[name] = [];
    }
    if (!_eventBindings[name]!.contains(listener)) {
      _eventBindings[name]!.add(listener);
    }

    return () {
      _eventBindings[name]?.remove(listener);
    };
  }

  void _notifyEventListeners(Event name, dynamic data) {
    final listeners = _eventBindings[name];
    if (listeners != null) {
      for (final listener in listeners) {
        listener(data);
      }
    }
  }

  /// Bind a callback to an MPV keypress event.
  Future<void> onKey(String name, Function callback) async {
    final keyBindingId = _keyBindingId++;
    final bindName = 'bind$keyBindingId';
    _keyBindings[bindName] = callback;

    try {
      await command('keybind', [name, 'script-message custom-bind $bindName']);
    } on MPVError catch (_) {
      await command('define-section',
          [bindName, '$name script-message custom-bind $bindName']);
      await command('enable-section', [bindName]);
    }
  }

  /// Bind a callback to an MPV property change.
  ///
  /// Returns a unique observer ID needed to destroy the observer.
  Future<ObserverID> observeProperty(
      Property name, PropertyObserverFunction fn) async {
    final observerId = _propertyObserverId++;
    _propertyBindings[observerId] = fn;
    await command('observe_property', [observerId, name]);
    return observerId;
  }

  /// Remove callback to an MPV property change.
  ///
  /// [id] is the unique observer ID returned from [observeProperty()].
  Future<void> unobserveProperty(ObserverID id) async {
    await command('unobserve_property', [id]);
    _propertyBindings.remove(id);
  }

  /// Waits for the value of a property to change.
  Future<void> waitForProperty(Property name) async {
    final completer = Completer();

    int eventsReceived = 0;
    final observerId = await observeProperty(name, (_, val) {
      if (eventsReceived == 1) {
        completer.complete();
      }
      eventsReceived++;
    });

    await completer.future;
    await unobserveProperty(observerId);
  }

  /// Play the specified URL. An alias to loadfile().
  Future<void> play(String url) {
    return command('loadfile', [url]);
  }

  /// Terminate the connection to MPV and process (if [launch()] is used).
  Future<void> terminate() async {
    _mpvInter.stop();
    await _mpvProcess?.stop();
  }

  /// Send a command to MPV.
  Future<T> command<T>(String command, [List args = const []]) {
    return _mpvInter.command<T>(command, args);
  }

  /// Get the value of a property.
  Future<T> getProperty<T>(Property name) async {
    final result = await command<T>('get_property', [name]);
    return result;
  }

  /// Set the value of a property.
  Future<void> setProperty(Property name, dynamic value) async {
    await command('set_property', [name, value]);
  }
}
