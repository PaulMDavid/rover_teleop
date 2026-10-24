package de.tuberlin.navws.rover_teleop

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navws/wifi").setMethodCallHandler { call, result ->
            if (call.method == "bindToWifi") {
                bindToWifi()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    // orintwo's access point has no internet, so Android would send this app's traffic
    // over mobile data and never reach 10.42.0.1. Pin the whole process to Wi-Fi.
    private fun bindToWifi() {
        if (wifiCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java)
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network)
            }

            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
            }
        }
        cm.requestNetwork(request, callback)
        wifiCallback = callback
    }

    override fun onDestroy() {
        wifiCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        super.onDestroy()
    }
}
