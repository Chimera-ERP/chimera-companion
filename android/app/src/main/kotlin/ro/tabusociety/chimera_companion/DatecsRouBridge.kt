package ro.tabusociety.chimera_companion

import com.datecs.fiscalprinter.rou.DP25ROU
import java.math.BigDecimal
import java.net.InetSocketAddress
import java.net.Socket
import java.net.Inet4Address
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Official Datecs Romania SDK, not the DP25MX ASCII gateway protocol. */
object DatecsRouBridge {
    fun lanNetworks(context: android.content.Context): List<Map<String, Any>> {
        val manager = context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        return manager.allNetworks.flatMap { network ->
            val capabilities = manager.getNetworkCapabilities(network)
            if (capabilities == null || !(capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) ||
                    capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET))) emptyList()
            else manager.getLinkProperties(network)?.linkAddresses.orEmpty().mapNotNull { address ->
                val ip = address.address as? Inet4Address ?: return@mapNotNull null
                val b = ip.address.map { it.toInt() and 255 }
                if (!(b[0] == 10 || b[0] == 192 && b[1] == 168 || b[0] == 172 && b[1] in 16..31)) null
                else mapOf("host" to ip.hostAddress!!, "prefix" to address.prefixLength)
            }
        }.distinctBy { it["host"] }
    }

    /** Discovery lists TCP endpoints independently of protocol validation. */
    fun discover(context: android.content.Context): List<Map<String, Any?>> {
        val targets = mutableSetOf<Pair<String, Int>>()
        for (address in lanNetworks(context)) {
            val bytes = (address["host"] as String).split('.').map { it.toInt() }
            val prefix = (address["prefix"] as Int).coerceIn(24, 30)
            val mask = -1 shl (32 - prefix)
            val local = (bytes[0] shl 24) or (bytes[1] shl 16) or (bytes[2] shl 8) or bytes[3]
            val subnet = local and mask
            val broadcast = subnet or mask.inv()
            for (host in subnet + 1 until broadcast) {
                if (host == local) continue
                val candidate = "${host ushr 24 and 255}.${host ushr 16 and 255}.${host ushr 8 and 255}.${host and 255}"
                for (port in listOf(3999, 4999, 8000)) targets.add(candidate to port)
            }
        }
        val executor = Executors.newFixedThreadPool(24)
        return try {
            val tasks = targets.map { (host, port) -> java.util.concurrent.Callable {
                val socket = Socket()
                try {
                    socket.connect(InetSocketAddress(host, port), 600)
                    mapOf<String, Any?>("host" to host, "port" to port, "connected" to true,
                        "description" to "TCP accesibil · protocol de verificat", "paymentMethods" to emptyList<Map<String, String>>())
                } catch (_: Exception) { null } finally { socket.close() }
            } }
            executor.invokeAll(tasks, 18, TimeUnit.SECONDS).mapNotNull { try { it.get() } catch (_: Exception) { null } }
        } finally { executor.shutdownNow() }
    }

    fun execute(method: String, args: Map<*, *>): Map<String, Any?> {
        val host = args["host"] as String
        val parts = host.split('.').map { it.toInt() }
        require(parts.size == 4 && parts.all { it in 0..255 })
        require(parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && parts[1] in 16..31))
        val port = (args["port"] as Number).toInt()
        require(port in 1..65535)
        val socket = Socket()
        var printer: DP25ROU? = null
        var dispatched = false
        var stage = "conectare TCP"
        try {
            socket.soTimeout = if (method == "status") 2000 else 15000
            socket.connect(InetSocketAddress(host, port), 5000)
            val device = DP25ROU(socket.getInputStream(), socket.getOutputStream())
            printer = device
            stage = "citire stare"
            device.queryStatus() // SDK performs the Romanian error/status checks.
            val current = device.command76Variant0Version0()
            val ready = current.get("receiptIsOpened") == "0"
            if (method == "status") return mapOf("ready" to ready,
                "protocolConfirmed" to true,
                "description" to if (ready) "Datecs pregătit" else "Datecs are un document deschis")
            if (!ready) return mapOf("outcome" to "rejected", "message" to "Document deschis pe Datecs")
            if (method == "xReport" || method == "zReport") {
                // 69 / option 2 is X. No caller-controlled report option can request Z.
                dispatched = true
                stage = "tipărire raport X"
                device.command69Variant0Version0(if (method == "zReport") "0" else "2")
                return mapOf("outcome" to "succeeded", "message" to if (method == "zReport") "Raport Z confirmat de Datecs." else "Raport X confirmat de Datecs. Ziua rămâne deschisă.")
            }
            val receipt = args["receipt"] as Map<*, *>
            val operator = args["operatorNumber"].toString()
            val password = args["operatorPassword"] as String
            val till = args["tillNumber"] as String
            val total = (receipt["totalMinor"] as Number).toLong()
            val methodName = receipt["paymentMethod"] as String
            val paymentCode = args[if (methodName == "cash") "cashPaymentCode" else "cardPaymentCode"] as String
            val lines = receipt["lines"] as List<*>
            // Validate the complete command before opening the legal document.
            require(receipt["currency"] == "RON" && total in 1..99999999 && lines.isNotEmpty())
            require(methodName == "cash" || (methodName == "card" &&
                (receipt["confirmedPaymentReference"] as? String)?.isNotBlank() == true))
            require(operator.toInt() in 1..16 && password.matches(Regex("\\d{4,8}")))
            require(till.matches(Regex("\\d{1,5}")) && paymentCode.matches(Regex("[PNCDIJKL]")))
            var sum = 0L
            for (raw in lines) {
                val line = raw as Map<*, *>
                require((line["name"] as String).matches(Regex("[^\\t\\r\\n]{1,30}")))
                require((line["vatGroup"] as String).matches(Regex("[A-G]")))
                val quantity = BigDecimal(line["quantity"] as String)
                val price = (line["unitPriceMinor"] as Number).toLong()
                val gross = (line["grossTotalMinor"] as Number).toLong()
                require(quantity > BigDecimal.ZERO && quantity.scale() <= 3 && price in 0..99999999)
                require(quantity.multiply(BigDecimal(price)).setScale(0, java.math.RoundingMode.HALF_UP).longValueExact() == gross)
                sum = Math.addExact(sum, gross)
            }
            require(sum == total)
            dispatched = true
            device.command48Variant0Version0(operator, password, till)
            for (raw in lines) {
                val line = raw as Map<*, *>
                device.command49Variant0Version14(line["name"] as String, "", line["vatGroup"] as String,
                    BigDecimal.valueOf((line["unitPriceMinor"] as Number).toLong(), 2).toPlainString(), line["quantity"] as String)
            }
            val subtotal = device.command51Variant0Version0().get("subTotal")
            require(BigDecimal(subtotal.trim()).movePointRight(2).longValueExact() == total)
            val payment = device.command53Variant0Version0(paymentCode, BigDecimal.valueOf(total, 2).toPlainString())
            require(payment.get("paidCode") == "R" && BigDecimal(payment.get("amountOut").trim()).compareTo(BigDecimal.ZERO) == 0)
            val closed = device.command56Variant0Version0()
            val number = closed.get("fiscalReceipt")
            require(!number.isNullOrBlank())
            return mapOf("outcome" to "succeeded", "reference" to number,
                "message" to "Bon confirmat de Datecs")
        } catch (error: Exception) {
            val reason = when (error) {
                is java.net.SocketTimeoutException -> "timeout"
                is java.net.ConnectException -> "conexiune refuzată"
                is IllegalArgumentException -> "configurație invalidă"
                else -> "eroare de comunicare (${error.javaClass.simpleName})"
            }
            return mapOf("outcome" to if (dispatched) "unknown" else "rejected",
                "description" to "Datecs: $stage — $reason",
                "message" to if (dispatched) "Datecs: $stage — $reason. Rezultat incert; verifică documentul pe ECR." else "Datecs: $stage — $reason")
        } finally {
            printer?.close()
            socket.close()
        }
    }
}
