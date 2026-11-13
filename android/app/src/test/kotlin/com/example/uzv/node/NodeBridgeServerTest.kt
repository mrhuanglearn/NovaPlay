package com.example.uzv.node

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class NodeBridgeServerTest {
    private val pairRegex = Regex("\"([^\"]+)\":\"([^\"]*)\"")
    private fun parseFlatTestJson(raw: String): Map<String, String>? {
        val t = raw.trim()
        if (!t.startsWith("{") || !t.endsWith("}")) return null
        val map = pairRegex.findAll(t).associate { it.groupValues[1] to it.groupValues[2] }
        return map.ifEmpty { null }
    }

    @Test
    fun `loopback bridge survives foreign client probe and accepts Node reconnect`() {
        val srv = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        val received = CopyOnWriteArrayList<Pair<String, String>>()
        val readyCount = CountDownLatch(2)
        val server = LoopbackBridgeSession(
            token = "tok123",
            onEvent = { ch, msg ->
                received.add(ch to msg)
                if (ch == "status" && msg.startsWith("Node ready")) {
                    readyCount.countDown()
                }
            },
            parseJson = ::parseFlatTestJson,
        )
        val acceptThread = thread(isDaemon = true) { server.acceptLoop(srv) }

        try {
            // 1. Foreign local process connects with wrong token -> rejected, but server keeps listening!
            Socket("127.0.0.1", srv.localPort).use { bad ->
                OutputStreamWriter(bad.getOutputStream(), Charsets.UTF_8).apply {
                    write("{\"hello\":\"wrong\"}\n")
                    flush()
                }
            }

            // 2. Real Node connects, sends valid hello + malformed frame + status frame
            val first = Socket("127.0.0.1", srv.localPort)
            val w1 = OutputStreamWriter(first.getOutputStream(), Charsets.UTF_8)
            val r1 = BufferedReader(InputStreamReader(first.getInputStream(), Charsets.UTF_8))
            w1.write("{\"hello\":\"tok123\"}\n")
            w1.write("{not-valid-json\n")
            w1.write("{\"c\":\"status\",\"m\":\"Node ready, version v20\"}\n")
            w1.flush()

            val deadline = System.currentTimeMillis() + 2000
            while (received.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(15)
            assertEquals(listOf("status" to "Node ready, version v20"), received.toList())

            // Server -> Node write through NodeHost.send delivers null failure on success
            synchronized(NodeHost) { NodeHost.session = server }
            val sendRes = java.util.concurrent.CompletableFuture<Pair<String, String>?>()
            NodeHost.send("{\"c\":\"catpaw\",\"m\":\"ping\"}\n") { sendRes.complete(it) }
            assertNull(sendRes.get(2, TimeUnit.SECONDS))
            assertEquals("{\"c\":\"catpaw\",\"m\":\"ping\"}", r1.readLine())

            // When session is absent, NodeHost.send reports not_connected
            synchronized(NodeHost) { NodeHost.session = null }
            val noSessionRes = java.util.concurrent.CompletableFuture<Pair<String, String>?>()
            NodeHost.send("{\"c\":\"catpaw\",\"m\":\"ping\"}\n") { noSessionRes.complete(it) }
            assertEquals("not_connected", noSessionRes.get(2, TimeUnit.SECONDS)?.first)
            synchronized(NodeHost) { NodeHost.session = server }

            // 3. First socket drops during idle -> Node reconnects to the SAME ServerSocket
            first.close()

            val second = Socket("127.0.0.1", srv.localPort)
            second.use { s2 ->
                val w2 = OutputStreamWriter(s2.getOutputStream(), Charsets.UTF_8)
                val r2 = BufferedReader(InputStreamReader(s2.getInputStream(), Charsets.UTF_8))
                w2.write("{\"hello\":\"tok123\"}\n")
                w2.write("{\"c\":\"status\",\"m\":\"Node ready, version v20\"}\n")
                w2.flush()

                readyCount.await(2, TimeUnit.SECONDS)
                assertEquals(2, received.count { it.first == "status" && it.second.startsWith("Node ready") })
                val reloadRes = java.util.concurrent.CompletableFuture<Pair<String, String>?>()
                NodeHost.send("{\"c\":\"catpaw\",\"m\":\"reload\"}\n") { reloadRes.complete(it) }
                assertNull(reloadRes.get(2, TimeUnit.SECONDS))
                assertEquals("{\"c\":\"catpaw\",\"m\":\"reload\"}", r2.readLine())
            }
        } finally {
            synchronized(NodeHost) { NodeHost.session = null }
            srv.close()
            acceptThread.join(1000)
        }
    }
}
