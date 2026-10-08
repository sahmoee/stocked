package com.sowens.stocked.imports

import com.sowens.stocked.data.Recipe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.InetAddress
import java.net.URI
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Dns
import java.util.concurrent.TimeUnit

object RecipeWebFetcher {
    suspend fun fetch(address: String): List<Recipe> = withContext(Dispatchers.IO) {
        var uri = URI(address.trim())
        repeat(5) {
            validate(uri)
            val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
                .connectTimeout(10,TimeUnit.SECONDS).readTimeout(10,TimeUnit.SECONDS).callTimeout(20,TimeUnit.SECONDS)
                .dns(object : Dns { override fun lookup(hostname: String): List<InetAddress> { val addresses = Dns.SYSTEM.lookup(hostname); require(addresses.isNotEmpty() && addresses.none { privateAddress(it) }) { "Private or local network destinations are not allowed." }; return addresses } }).build()
            val request = Request.Builder().url(uri.toString()).header("Accept","text/html,application/ld+json,application/json").header("User-Agent","Stocked-Android/0.1 RecipeImport").build()
            client.newCall(request).execute().use { response ->
                val status = response.code
                if(status in 300..399) { val location = response.header("Location") ?: error("Redirect has no destination."); uri = uri.resolve(location); return@repeat }
                require(status in 200..299) { "Website returned HTTP $status." }
                val body = response.body ?: error("Website returned no content.")
                val type = body.contentType()?.toString().orEmpty().lowercase()
                require(type.contains("html") || type.contains("json")) { "Website did not return HTML or JSON." }
                require(body.contentLength() <= RecipeImporter.MAX_BYTES) { "Page exceeds 2 MB." }
                val bytes = body.byteStream().use { input -> val output = java.io.ByteArrayOutputStream(); val buffer=ByteArray(8192); var total=0; while(true) { val read=input.read(buffer); if(read<0) break; total+=read; require(total<=RecipeImporter.MAX_BYTES) { "Page exceeds 2 MB." }; output.write(buffer,0,read) }; output.toByteArray() }
                val text = bytes.toString(Charsets.UTF_8)
                if(type.contains("json")) return@withContext RecipeImporter.parse(text,uri.toString())
                val recipes = extractRecipes(text,uri.toString())
                require(recipes.isNotEmpty()) { "No structured recipe was found. Paste the ingredients and steps instead. Video and social recipes are not extracted." }
                require(recipes.size<=250); recipes.forEach { com.sowens.stocked.data.KitchenRules.validate(it) }
                return@withContext recipes
            }
        }
        error("Website redirected too many times.")
    }
    internal fun extractRecipes(text: String, source: String): List<Recipe> {
        val scripts = Regex("<script\\b[^>]*type\\s*=\\s*['\"]application/ld\\+json['\"][^>]*>(.*?)</script\\s*>", setOf(RegexOption.IGNORE_CASE,RegexOption.DOT_MATCHES_ALL)).findAll(text)
        val recipes = scripts.flatMap { match -> runCatching { RecipeImporter.json(match.groupValues[1],source) }.getOrDefault(emptyList()).asSequence() }.toList().distinctBy { it.title }
        return recipes
    }
    private fun validate(uri: URI) {
        require(uri.scheme.equals("https",true) && uri.userInfo==null && (uri.port==-1 || uri.port==443)) { "Use a public HTTPS recipe URL without credentials or a custom port." }
        val host = uri.host?.lowercase() ?: error("URL needs a hostname.")
        require(host != "localhost" && !host.endsWith(".local") && !host.endsWith(".internal")) { "Local network recipe URLs are not allowed." }
        val addresses = InetAddress.getAllByName(host)
        require(addresses.isNotEmpty() && addresses.none { privateAddress(it) }) { "Private or local network destinations are not allowed." }
    }
    internal fun privateAddress(address: InetAddress): Boolean {
        if(address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress || address.isMulticastAddress) return true
        val bytes=address.address.map { it.toInt() and 255 }
        return if(bytes.size==4) bytes[0]==0 || bytes[0]>=224 || bytes[0]==100 && bytes[1] in 64..127 || bytes[0]==198 && bytes[1] in 18..19
        else bytes[0] and 0xfe == 0xfc || bytes.size==16 && bytes.take(10).all { it==0 } && bytes[10]==255 && bytes[11]==255 && privateAddress(InetAddress.getByAddress(address.address.copyOfRange(12,16)))
    }
}
