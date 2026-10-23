import 'package:connectivity_plus/connectivity_plus.dart';

/// True when the device reports an active network interface.
///
/// This is a link-layer check, not a reachability guarantee (e.g. a Wi-Fi
/// network with no internet still reports "connected"), so callers should
/// still catch request failures and fall back regardless of this result.
Future<bool> hasNetworkLink() async {
  final results = await Connectivity().checkConnectivity();
  return results.any((r) => r != ConnectivityResult.none);
}
