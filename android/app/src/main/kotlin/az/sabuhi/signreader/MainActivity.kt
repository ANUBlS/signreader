package az.sabuhi.signreader

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "signreader/net")
            .setMethodCallHandler { call, result ->
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                when (call.method) {
                    // The 70mai Wi-Fi has no internet, so Android routes app traffic over mobile
                    // data and the dashcam (192.168.0.1) is unreachable. Bind the whole process,
                    // including native RTSP sockets, to the Wi-Fi network.
                    "bindWifi" -> {
                        @Suppress("DEPRECATION")
                        val wifi = cm.allNetworks.firstOrNull {
                            cm.getNetworkCapabilities(it)
                                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                        }
                        result.success(if (wifi != null) cm.bindProcessToNetwork(wifi) else false)
                    }
                    "unbind" -> result.success(cm.bindProcessToNetwork(null))
                    else -> result.notImplemented()
                }
            }
    }
}
