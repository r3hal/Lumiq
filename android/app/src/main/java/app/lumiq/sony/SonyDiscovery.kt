package app.lumiq.sony

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.URL
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

data class SonyDiscoveredCamera(val host: String, val model: String, val descriptorUrl: String)

/** The phone's Wi-Fi link: the network to send camera traffic over, and its IPv4 subnet. */
data class SonyWifiLink(val network: Network, val address: Long, val prefixLength: Int) {
    /**
     * Opens camera connections on this Wi-Fi network. A camera's DIRECT Wi-Fi has no internet, so
     * Android would otherwise send these requests over mobile data.
     */
    val connector = SonyConnector { url -> network.openConnection(url) as HttpURLConnection }

    companion object {
        fun find(context: Context): SonyWifiLink? {
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
            @Suppress("DEPRECATION")
            for (network in manager.allNetworks) {
                val caps = manager.getNetworkCapabilities(network) ?: continue
                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                val link = manager.getLinkProperties(network) ?: continue
                for (la in link.linkAddresses) {
                    val inet = la.address as? Inet4Address ?: continue
                    val address = SonyDiscovery.number(inet.hostAddress ?: continue) ?: continue
                    return SonyWifiLink(network, address, la.prefixLength)
                }
            }
            return null
        }
    }
}

/** Bounded unicast discovery on the actual Wi-Fi subnet: no fixed IP, no multicast, no SDK. */
object SonyDiscovery {
    fun ipv4(a: Long) = "${(a shr 24) and 255}.${(a shr 16) and 255}.${(a shr 8) and 255}.${a and 255}"

    fun number(host: String): Long? {
        if (!SonyEndpoint.validHost(host)) return null
        return host.split(".").fold(0L) { acc, part -> (acc shl 8) or part.toLong() }
    }

    fun mask(prefixLength: Int): Long = if (prefixLength <= 0) 0L else (0xffffffffL shl (32 - prefixLength)) and 0xffffffffL

    /** Up to 64 likely camera addresses: the last used one, the start of the subnet and neighbours of the phone. */
    fun candidates(address: Long, mask: Long, previous: String? = null): List<String> {
        val inverse = mask.inv() and 0xffffffffL
        if (mask == 0L || inverse < 3 || (inverse and (inverse + 1)) != 0L || !SonyEndpoint.validHost(ipv4(address))) return emptyList()
        val network = address and mask
        val broadcast = network or inverse
        val values = LinkedHashSet<Long>()
        fun add(c: Long) {
            if (c > network && c < broadcast && c != address && SonyEndpoint.validHost(ipv4(c))) values += c
        }
        previous?.let { p -> number(p)?.let { if ((it and mask) == network) add(it) } }
        for (offset in 1..32) add(network + offset)
        for (offset in -16..16) add(address + offset)
        return values.take(64).map(::ipv4)
    }

    fun probe(host: String, connector: SonyConnector): SonyDiscoveredCamera? {
        for (port in listOf(64321, 61000)) {
            val url = "http://$host:$port/DmsRmtDesc.xml"
            try {
                val c = connector.open(URL(url))
                try {
                    c.connectTimeout = 800; c.readTimeout = 1_200; c.instanceFollowRedirects = false; c.useCaches = false
                    if (c.responseCode != 200) continue
                    val data = c.inputStream.use { SonyApiClient.readLimited(it, 512 * 1024) }
                    val descriptor = SonyDescriptor.parse(data, host)
                    return SonyDiscoveredCamera(host, descriptor.model, url)
                } finally { c.disconnect() }
            } catch (_: Exception) {
            }
        }
        return null
    }

    /** Blocking; at most four probes at a time. */
    fun discover(link: SonyWifiLink, previous: String?): List<SonyDiscoveredCamera> {
        val hosts = candidates(link.address, mask(link.prefixLength), previous)
        if (hosts.isEmpty()) return emptyList()
        val pool = Executors.newFixedThreadPool(4)
        return try {
            pool.invokeAll(hosts.map { h -> Callable { probe(h, link.connector) } }, 40, TimeUnit.SECONDS)
                .mapNotNull { runCatching { it.get() }.getOrNull() }.sortedBy { it.host }
        } finally {
            pool.shutdownNow()
        }
    }
}
