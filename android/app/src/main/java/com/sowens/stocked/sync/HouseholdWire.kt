package com.sowens.stocked.sync

import com.sowens.stocked.data.*
import kotlinx.serialization.json.*
import java.util.UUID
import java.time.Instant

/** Pure wire transforms. Local edits win on overlap; server tombstones never erase unsent edits. */
object HouseholdWire {
 data class Collection(val key:String,val deleted:String,val type:String)
 val collections=listOf(Collection("inventory","invDeleted","inventoryItem"),Collection("grocery","groDeleted","groceryItem"),Collection("userRecipes","userRecipeDeleted","userRecipe"),Collection("plannedMeals","mealDeleted","plannedMeal"))
 fun rows(doc:JsonObject,key:String)= (doc[key] as? JsonArray).orEmpty().map{it.jsonObject}.associateBy{it.getValue("id").jsonPrimitive.content}
 fun document(state:KitchenState):JsonObject {
  val root=BackupCodec.json.parseToJsonElement(BackupCodec.export(state)).jsonObject.toMutableMap()
  root.remove("_androidHousehold")
  // Household inventory uses the shipped iOS `zone` wire key. Backup JSON uses
  // `storageCategory`; neither contract may silently change the other.
  root["inventory"] = JsonArray((root["inventory"] as? JsonArray).orEmpty().map { value ->
   val row=value.jsonObject
   JsonObject(row.filterKeys { it!="storageCategory" } + ("zone" to (row["storageCategory"] ?: row["zone"] ?: JsonPrimitive("Pantry"))))
  })
  root["userRecipes"] = JsonArray((root["userRecipes"] as? JsonArray).orEmpty().map { value ->
   val row=value.jsonObject.toMutableMap()
   row.putIfAbsent("difficulty",JsonPrimitive("Medium"))
   row.putIfAbsent("dishRole",JsonPrimitive("unspecified"))
   val created=row["dateCreated"] as? JsonPrimitive
   row["dateCreated"] = if(created?.isString==true) JsonPrimitive(Instant.parse(created.content).toEpochMilli()/1000.0-978307200.0)
    else created ?: JsonPrimitive((row["updatedAt"]?.jsonPrimitive?.doubleOrNull ?: 978307200000.0)/1000.0-978307200.0)
   val lastCooked=row["lastCooked"] as? JsonPrimitive
   if(lastCooked?.isString==true)row["lastCooked"]=JsonPrimitive(Instant.parse(lastCooked.content).toEpochMilli()/1000.0-978307200.0)
   row["ingredients"]=JsonArray((row["ingredients"] as? JsonArray).orEmpty().map{ingredient ->
    val fields=ingredient.jsonObject.toMutableMap();fields.putIfAbsent("isOptional",JsonPrimitive(false));JsonObject(fields)
   })
   JsonObject(row)
  })
  root["plannedMeals"]=JsonArray(((root.remove("planned") ?: JsonArray(emptyList())) as JsonArray).map { value ->
   val row=value.jsonObject.toMutableMap();row.putIfAbsent("isBuilding",JsonPrimitive(false));row.putIfAbsent("cookAheadStatus",JsonPrimitive("none"));JsonObject(row)
  })
  return JsonObject(root)
 }
 fun kitchen(doc:JsonObject,local:KitchenState):KitchenState {
  val data=mutableMapOf<String,JsonElement>("schemaVersion" to JsonPrimitive(1))
  collections.forEach{collection ->
   val value=doc[collection.key] ?: JsonArray(emptyList())
   data[if(collection.key=="plannedMeals")"planned" else collection.key] = if(collection.key=="inventory") {
    JsonArray(value.jsonArray.map { item -> val row=item.jsonObject
     JsonObject(row + ("storageCategory" to (row["zone"] ?: row["storageCategory"] ?: JsonPrimitive("Pantry"))))
    })
   } else value
  }
  val incoming=BackupCodec.preview(JsonObject(data).toString(),KitchenState()).incoming
  return incoming.copy(extra=local.extra)
 }
 const val MAX_BATCH_BYTES=1800*1024
 fun batch(base:JsonObject,local:JsonObject,revision:Long):JsonObject {
  val operations=mutableListOf<JsonElement>();val quantities=mutableListOf<JsonElement>();val payload=mutableMapOf<String,JsonElement>()
  // Reserve keys, separators, request ID and array framing. Every candidate is
  // measured after JSON escaping in UTF-8; character counts are not byte counts.
  var usedBytes=4096
  var full=false
  fun bytes(value:JsonElement?)=value?.toString()?.toByteArray(Charsets.UTF_8)?.size ?: 0
  collections.forEach { c ->
   val old=rows(base,c.key);val current=rows(local,c.key);val changed=mutableListOf<JsonElement>();val deleted=mutableListOf<JsonElement>()
   val tombstones=(base[c.deleted] as? JsonArray).orEmpty().map{it.jsonPrimitive.content}.toSet()
   (old.keys+current.keys).forEach records@{ id ->
    val before=old[id];val after=current[id]
    if(before==after || full || operations.size>=200)return@records
    require(after==null || id !in tombstones){"An offline edit conflicts with a deleted household record. Export a backup and duplicate it with a new ID before syncing."}
    val opID=UUID.randomUUID().toString()
    val operation=buildJsonObject {put("operationId",opID);put("idempotencyKey",opID);put("entityId",id);put("entityType",c.type);put("operationType",if(after==null)"delete" else if(before==null)"create" else "update");put("baseServerRevision",revision);put("createdAt",System.currentTimeMillis())}
    val delta=if(before!=null && after!=null && c.key in setOf("inventory","grocery")) (after["quantity"]?.jsonPrimitive?.intOrNull ?: 0)-(before["quantity"]?.jsonPrimitive?.intOrNull ?: 0) else 0
    val quantity=if(delta!=0){val qID=UUID.randomUUID().toString();buildJsonObject{put("operationId",qID);put("idempotencyKey",qID);put("entityId",id);put("entityType",c.type);put("delta",delta);put("baseValue",before!!.getValue("quantity"));put("createdAt",System.currentTimeMillis())}}else null
    val record=if(after!=null && delta!=0)JsonObject(after+("quantity" to before!!.getValue("quantity")))else after
    val deletion=if(after==null)JsonPrimitive(id)else null
    val candidateBytes=bytes(operation)+bytes(quantity)+bytes(record)+bytes(deletion)+16
    if(usedBytes+candidateBytes>MAX_BATCH_BYTES){
     require(operations.isNotEmpty()){"One household record is too large to sync. Export a backup, then remove large images or shorten that record before retrying. Local data has been retained."}
     full=true;return@records
    }
    usedBytes+=candidateBytes;operations+=operation
    quantity?.let{quantities+=it};record?.let{changed+=it};deletion?.let{deleted+=it}
   }
   payload[c.key]=JsonArray(changed);payload[c.deleted]=JsonArray(deleted)
  }
  payload["syncProtocolVersion"]=JsonPrimitive(2);payload["requestId"]=JsonPrimitive(UUID.randomUUID().toString());payload["operations"]=JsonArray(operations);payload["quantityOperations"]=JsonArray(quantities)
  return JsonObject(payload).also{check(bytes(it)<=MAX_BATCH_BYTES){"Household batch exceeds the safe transport limit."}}
 }
 fun sentSnapshot(base:JsonObject,current:JsonObject,batch:JsonObject):JsonObject {
  val result=base.toMutableMap()
  collections.forEach{c->val values=rows(base,c.key).toMutableMap();val local=rows(current,c.key)
   batch.getValue("operations").jsonArray.map{it.jsonObject}.filter{it.getValue("entityType").jsonPrimitive.content==c.type}.forEach{op->val id=op.getValue("entityId").jsonPrimitive.content;if(local[id]==null)values.remove(id)else values[id]=local.getValue(id)}
   result[c.key]=JsonArray(values.values.toList())
  };return JsonObject(result)
 }
 fun merge(base:JsonObject,current:JsonObject,remote:JsonObject):JsonObject {
  val result=remote.toMutableMap()
  collections.forEach { c ->
   val before=rows(base,c.key);val local=rows(current,c.key);val server=rows(remote,c.key).toMutableMap()
   val tombstones=(remote[c.deleted] as? JsonArray).orEmpty().map{it.jsonPrimitive.content}.toSet()
   tombstones.forEach{server.remove(it)}
   (before.keys+local.keys).forEach{id->if(before[id]!=local[id]){if(local[id]==null)server.remove(id) else server[id]=local.getValue(id)}}
   result[c.key]=JsonArray(server.values.toList())
  }
  return JsonObject(result)
 }
}
