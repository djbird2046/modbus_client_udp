import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:synchronized/synchronized.dart';

/// The Modbus UDP client class.
class ModbusClientUdp extends ModbusClient {
  final String serverAddress;
  final int serverPort;
  final Duration connectionTimeout;
  final Duration? delayAfterConnect;

  @override
  bool get isConnected => _socket != null;

  int _lastTransactionId = 0;

  int _getNextTransactionId() {
    // UInt16 rollover handling
    _lastTransactionId++;
    if (_lastTransactionId > 65535) {
      _lastTransactionId = 0;
    }
    return _lastTransactionId;
  }

  RawDatagramSocket? _socket;
  final Lock _lock = Lock();
  _UdpResponse? _currentResponse;

  ModbusClientUdp(this.serverAddress,
      {this.serverPort = 502,
        super.connectionMode = ModbusConnectionMode.autoConnectAndKeepConnected,
        this.connectionTimeout = const Duration(seconds: 3),
        super.responseTimeout = const Duration(seconds: 3),
        this.delayAfterConnect,
        super.unitId});

  @override
  Future<ModbusResponseCode> send(ModbusRequest request) async {
    var res = await _lock.synchronized(() async {
      // Connect if needed
      try {
        if (connectionMode != ModbusConnectionMode.doNotConnect) {
          await connect();
        }
        if (!isConnected) {
          return ModbusResponseCode.connectionFailed;
        }
      } catch (ex) {
        ModbusAppLogger.severe(
            "Unexpected exception in sending UDP message", ex);
        return ModbusResponseCode.connectionFailed;
      }

      // Create the new response handler
      var transactionId = _getNextTransactionId();
      _currentResponse = _UdpResponse(request, transactionId: transactionId, timeout: getResponseTimeout(request));

      // Reset this request in case it was already used before
      request.reset();

      // Create request data
      int pduLen = request.protocolDataUnit.length;
      var header = Uint8List(pduLen + 7);
      ByteData.view(header.buffer)
        ..setUint16(0, transactionId) // Transaction ID
        ..setUint16(2, 0) // Protocol ID = 0
        ..setUint16(4, pduLen + 1) // PDU Length + Unit ID byte
        ..setUint8(6, getUnitId(request)); // Unit ID
      header.setAll(7, request.protocolDataUnit);

      // Send the request data
      _socket!.send(header, InternetAddress(serverAddress), serverPort);

      // Wait for the response code
      return await request.responseCode;
    });
    // Need to disconnect?
    if (connectionMode == ModbusConnectionMode.autoConnectAndDisconnect) {
      await disconnect();
    }
    return res;
  }

  /// Connect the socket if not already done or disconnected
  @override
  Future<bool> connect() async {
    if (isConnected) {
      return true;
    }
    ModbusAppLogger.fine("Connecting UDP socket...");
    // New connection
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // listen to the received data event stream
      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram = _socket!.receive();
          if (datagram != null) {
            _onSocketData(datagram.data);
          }
        }
      }, onError: (error) => _onSocketError(error),
          onDone: () => disconnect(),
          cancelOnError: true);
    } catch (ex) {
      ModbusAppLogger.warning(
          "Connection to $serverAddress:$serverPort failed!", ex);
      _socket = null;
      return false;
    }
    // Is a delay requested?
    if (delayAfterConnect != null) {
      await Future.delayed(delayAfterConnect!);
    }
    ModbusAppLogger.fine("UDP socket connected");
    return true;
  }

  /// Handle received data from the socket
  void _onSocketData(Uint8List data) {
    // Could receive buffered data before setting up the response object
    _currentResponse?.addResponseData(data);
  }

  /// Handle an error from the socket
  void _onSocketError(dynamic error) {
    ModbusAppLogger.severe("Unexpected error from UDP socket", error);
    disconnect();
  }

  /// Handle socket being closed
  @override
  Future<void> disconnect() async {
    ModbusAppLogger.fine("Disconnecting UDP socket...");
    if (_socket != null) {
      _socket!.close();
      _socket = null;
    }
  }
}

class _UdpResponse {
  final ModbusRequest request;
  final int transactionId;
  final Duration timeout;

  final Completer _timeout = Completer();
  List<int> _data = Uint8List(0);
  int? _resDataLen;

  _UdpResponse(this.request,
      {required this.timeout, required this.transactionId}) {
    _timeout.future.timeout(timeout, onTimeout: () {
      request.setResponseCode(ModbusResponseCode.requestTimeout);
    });
  }

  void addResponseData(Uint8List data) {
    // Timeout expired?
    if (_timeout.isCompleted) {
      // No more data needed, we've already set the response code
      return;
    }
    _data += data;
    // Still need the UDP header?
    if (_resDataLen == null && _data.length >= 6) {
      var resView = ByteData.view(Uint8List.fromList(_data).buffer, 0, 6);
      if (transactionId != resView.getUint16(0)) {
        ModbusAppLogger.warning("Invalid UDP transaction id",
            "$transactionId != ${resView.getUint16(0)}");
        _timeout.complete();
        request.setResponseCode(ModbusResponseCode.requestRxFailed);
        return;
      }
      if (0 != resView.getUint16(2)) {
        ModbusAppLogger.warning(
            "Invalid UDP protocol id", "${resView.getUint16(2)} != 0");
        _timeout.complete();
        request.setResponseCode(ModbusResponseCode.requestRxFailed);
        return;
      }
      _resDataLen = resView.getUint16(4);
    }
    // Got all data
    if (_resDataLen != null && _data.length >= _resDataLen!) {
      _timeout.complete();
      request.setFromPduResponse(data.sublist(7));
    }
  }
}