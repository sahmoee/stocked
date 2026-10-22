package com.sowens.stocked.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import com.sowens.stocked.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.File
import java.net.URL
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.HttpsURLConnection

/** Credentials cannot migrate through Android backup or exported kitchen JSON. */
private class MembershipVault(context:Context) {
 private val file=AtomicFile(File(context.noBackupFilesDir,"household-identity.sealed"))
 private fun key():SecretKey {
  val store=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
  (store.getKey("stocked.household.identity.v1",null) as? SecretKey)?.let{return it}
  return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{init(KeyGenParameterSpec.Builder("stocked.household.identity.v1",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())}.generateKey()
 }
 fun identity():Pair<String,String> {
  if(file.baseFile.exists() || File(file.baseFile.path+".bak").exists()) {
   val bytes=file.openRead().use{input->val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(512);while(true){val n=input.read(buffer);if(n<0)break;require(out.size()+n<=4096);out.write(buffer,0,n)};out.toByteArray()};require(bytes.size>=29)
   val cipher=Cipher.getInstance("AES/GCM/NoPadding").apply{init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,bytes.copyOfRange(0,12)))}
   val parts=String(cipher.doFinal(bytes.copyOfRange(12,bytes.size)),Charsets.UTF_8).split('\n');require(parts.size==2);return parts[0] to parts[1]
  }
  val id=UUID.randomUUID().toString();val secret=Base64.encodeToString(ByteArray(32).also{SecureRandom().nextBytes(it)},Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
  val cipher=Cipher.getInstance("AES/GCM/NoPadding").apply{init(Cipher.ENCRYPT_MODE,key())}
  val output=file.startWrite();try{output.write(cipher.iv+cipher.doFinal("$id\n$secret".toByteArray()));file.finishWrite(output)}catch(e:Exception){file.failWrite(output);throw e}
  return id to secret
 }
}

class HouseholdClient(context:Context,private val repository:KitchenRepository,private val endpoint:String) {
 companion object {
  const val JOURNAL="_androidHousehold"
  private val processMutex=Mutex()
  @Volatile private var instance:HouseholdClient?=null
  fun get(context:Context,repository:KitchenRepository,endpoint:String):HouseholdClient=instance ?: synchronized(this){instance ?: HouseholdClient(context.applicationContext,repository,endpoint).also{instance=it}}
 }
 private val vault=MembershipVault(context.applicationContext)
 private val mutex=processMutex
 private val appContext=context.applicationContext
 private var automatic:HouseholdScheduler?=null
 fun startAutomaticSync(){synchronized(this){if(automatic==null)automatic=HouseholdScheduler(appContext,repository,this,endpoint).also{it.start()}}}
 fun pendingWork():Boolean { val j=journal(repository.state.value); if(j["pending"]!=null)return true;if(code().isEmpty() || role() in setOf("kid","viewer","readonly","readOnly"))return false;val base=j["baseline"]?.jsonObject ?: JsonObject(emptyMap());val current=HouseholdWire.document(repository.state.value);return HouseholdWire.collections.any{HouseholdWire.rows(base,it.key)!=HouseholdWire.rows(current,it.key)} }
 private val status=MutableStateFlow("Manual sync ready")
 val message=status.asStateFlow()
 private fun journal(state:KitchenState)=state.extra[JOURNAL] as? JsonObject ?: JsonObject(emptyMap())
 fun code():String=journal(repository.state.value)["code"]?.jsonPrimitive?.content.orEmpty()
 fun role():String=journal(repository.state.value)["role"]?.jsonPrimitive?.content ?: "member"
 private fun save(state:KitchenState,journal:JsonObject)=state.copy(extra=JsonObject(state.extra+(JOURNAL to journal)))
 private fun call(action:String,body:JsonObject,identity:Pair<String,String>):JsonObject {
  require(endpoint.startsWith("https://")) { "Household endpoint must use HTTPS." }
  val connection=URL(endpoint.trimEnd('/')+"/"+action).openConnection() as HttpsURLConnection
  connection.connectTimeout=15000;connection.readTimeout=20000;connection.instanceFollowRedirects=false;connection.requestMethod="POST";connection.doOutput=true
  connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("X-Household-Member",identity.first);connection.setRequestProperty("X-Household-Credential",identity.second)
  val payload=body.toString().toByteArray();require(payload.size<=2*1024*1024){"Sync batch exceeds the service’s 2 MB limit; export a backup and shorten large records."}
  try { connection.setFixedLengthStreamingMode(payload.size);connection.outputStream.use{it.write(payload)}
   val code=connection.responseCode;val input=if(code in 200..299)connection.inputStream else connection.errorStream
   val out=java.io.ByteArrayOutputStream();input?.use{val buffer=ByteArray(8192);while(true){val n=it.read(buffer);if(n<0)break;require(out.size()+n<=10*1024*1024){"Household response exceeds limit."};out.write(buffer,0,n)}}
   require(code in 200..299){when(code){401,403->"Household membership rejected. Rejoin or ask the owner for access.";429->"Household service is busy. Try later.";else->"Household request failed (HTTP $code)."}}
   return BackupCodec.json.parseToJsonElement(out.toString("UTF-8")).jsonObject
  } finally {connection.disconnect()}
 }
 private suspend fun runWork(work:suspend ()->Unit)=withContext(Dispatchers.IO){mutex.withLock{try{status.value="Connecting…";work()}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(e:Exception){status.value=e.message ?: "Sync failed; local changes are retained.";throw e}}}
 suspend fun enroll(name:String,joinCode:String?=null)=runWork {
  require(code().isEmpty()){ "Leave your current household first." };require(name.trim().length in 1..60)
  val identity=vault.identity();var supplied=joinCode?.trim().orEmpty();var token=""
  if(supplied.startsWith("https://")){val uri=android.net.Uri.parse(supplied);token=uri.getQueryParameter("invite") ?: uri.getQueryParameter("token") ?: uri.getQueryParameter("inviteToken").orEmpty();supplied=uri.getQueryParameter("code") ?: uri.lastPathSegment.orEmpty()}
  if(joinCode!=null)require(supplied.matches(Regex("[A-Za-z0-9]{6,16}"))){"Enter a household code or invite link."}
  val response=call(if(joinCode==null)"create" else "join",buildJsonObject{put("memberId",identity.first);put("memberName",name.trim());put("ownerName",name.trim());if(joinCode!=null)put("code",supplied);if(token.isNotEmpty())put("invite",token)},identity)
  val remote=response["household"]?.jsonObject ?: error("Missing household response.")
  repository.transformState { local ->
   val merged=HouseholdWire.merge(JsonObject(emptyMap()),HouseholdWire.document(local),remote)
   save(HouseholdWire.kitchen(merged,local),buildJsonObject{put("code",remote.getValue("code"));put("name",name.trim());put("baseline",remote);put("role",memberRole(remote,identity.first));put("revision",remote["revision"] ?: JsonPrimitive(0))})
  };status.value="Household connected. Your local entries are retained and will sync when connected.";startAutomaticSync();automatic?.connected()
 }
 private fun memberRole(remote:JsonObject,id:String)=if(remote["ownerId"]?.jsonPrimitive?.content==id)"owner" else (remote["members"] as? JsonArray).orEmpty().map{it.jsonObject}.find{it["memberId"]?.jsonPrimitive?.content==id}?.get("role")?.jsonPrimitive?.content ?: "viewer"
 suspend fun sync()=runWork {
  val identity=vault.identity();var local=repository.state.value;var j=journal(local);require(code().isNotEmpty()){ "Create or join a household first." }
  require(System.currentTimeMillis()>=(j["retryAfter"]?.jsonPrimitive?.longOrNull ?: 0)){"Sync paused after a failure. Try later; changes remain saved."}
  try {
   if(j["pending"]==null && role() !in setOf("kid","viewer","readonly","readOnly")) {
    repository.transformState{ state -> val current=journal(state);val snapshot=HouseholdWire.document(state);val batch=HouseholdWire.batch(current["baseline"]?.jsonObject ?: JsonObject(emptyMap()),snapshot,current["revision"]?.jsonPrimitive?.longOrNull ?: 0)
     require(role() !in setOf("member","teen") || batch.getValue("operations").jsonArray.none{op->val row=op.jsonObject;row["operationType"]?.jsonPrimitive?.content=="delete" && row["entityType"]?.jsonPrimitive?.content in setOf("inventoryItem","groceryItem")}){"Your household role cannot delete shared inventory or groceries. Restore those local entries before syncing, or ask the owner to change your role."}
     if(batch.getValue("operations").jsonArray.isEmpty())state else save(state,JsonObject(current+("pending" to batch)+("snapshot" to HouseholdWire.sentSnapshot(current["baseline"]?.jsonObject ?: JsonObject(emptyMap()),snapshot,batch)))) }
   }
   local=repository.state.value;j=journal(local)
   val pending=j["pending"] as? JsonObject
   pending?.get("operations")?.jsonArray?.forEach{op->val created=op.jsonObject["createdAt"]?.jsonPrimitive?.longOrNull ?: 0;require(System.currentTimeMillis()-created<28L*24*60*60*1000){"Pending sync is older than the server replay-safety window. Export a backup and review with the household owner; it has not been resent."}}
   val body=buildJsonObject{put("code",j.getValue("code"));put("memberId",identity.first);put("actorId",identity.first);put("memberName",j["name"] ?: JsonPrimitive("Android"));pending?.forEach{(k,v)->put(k,v)}}
   val response=call(if(pending==null)"pull" else "push",body,identity)
   val remote=response["household"]?.jsonObject ?: error("Missing household data; local records retained.")
   if(pending!=null){val acknowledged=response["receipt"]?.jsonObject?.get("acknowledgedIdempotencyKeys")?.jsonArray?.map{it.jsonPrimitive.content}?.toSet().orEmpty();val requested=(pending.getValue("operations").jsonArray+pending.getValue("quantityOperations").jsonArray).map{it.jsonObject.getValue("idempotencyKey").jsonPrimitive.content};if(!requested.all{it in acknowledged}) {
    // Retry rejected keys after role changes, while acknowledged operation keys remain
    // unchanged for server-side deduplication. A new request avoids replaying a partial receipt.
    repository.transformState{state->val current=journal(state);save(state,JsonObject(current+("pending" to JsonObject(pending+("requestId" to JsonPrimitive(UUID.randomUUID().toString()))))))}
    error("Some changes were rejected. Pending changes are retained for review; no local records were replaced.")
   }}
   repository.transformState { state -> val current=journal(state);val base=if(pending!=null)current.getValue("snapshot").jsonObject else current["baseline"]?.jsonObject ?: JsonObject(emptyMap());val merged=HouseholdWire.merge(base,HouseholdWire.document(state),remote)
    save(HouseholdWire.kitchen(merged,state),JsonObject(current.filterKeys{it !in setOf("pending","snapshot","retryAfter","failures")}+("baseline" to remote)+("revision" to (remote["revision"] ?: JsonPrimitive(0)))+("role" to JsonPrimitive(memberRole(remote,identity.first))))) }
   status.value=if(role() in setOf("kid","viewer","readonly","readOnly"))"Read-only household refreshed; local edits remain on this device." else "Household synced. Offline edits are saved on this device."
  } catch(e:Exception){if(e is kotlinx.coroutines.CancellationException)throw e;repository.transformState{state->val current=journal(state);val failures=((current["failures"]?.jsonPrimitive?.intOrNull ?: 0)+1).coerceAtMost(8);save(state,JsonObject(current+("failures" to JsonPrimitive(failures))+("retryAfter" to JsonPrimitive(System.currentTimeMillis()+minOf(300000L,5000L*(1L shl failures))))))};throw e}
 }
 suspend fun leave()=runWork {val identity=vault.identity();val j=journal(repository.state.value);require(j["pending"]==null){"Sync pending changes before leaving; your local data is preserved."};call("leave",buildJsonObject{put("code",j.getValue("code"));put("memberId",identity.first);put("actorId",identity.first)},identity);repository.transformState{it.copy(extra=JsonObject(it.extra.filterKeys{key->key!=JOURNAL}))};status.value="Left household. Local kitchen retained.";automatic?.disconnected()}
}
