package com.sowens.stocked.data

import kotlinx.serialization.json.*
import kotlinx.serialization.serializer
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.UUID

object BackupCodec {
 val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
 private const val MAX_BYTES = 10 * 1024 * 1024
 fun preview(text: String, current: KitchenState): ImportPreview {
  require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "Backup exceeds the 10 MB import limit." }
  val root = json.parseToJsonElement(text).jsonObject
  require(!root.containsKey("sealedPayload")) { "Encrypted .stocked backups require a recovery key. Export readable JSON from iOS instead." }
  val version = root["schemaVersion"]?.jsonPrimitive?.intOrNull ?: 1
  require(version in 1..3) { "This backup uses an unsupported schema version." }
  val sectionKeys = setOf("inventoryItems", "groceryItems", "plannedMeals", "userRecipes", "pastMeals", "savedRecipes", "generatedRecipes", "inventory", "grocery", "planned", "recipes")
  require(sectionKeys.any { root.containsKey(it) }) { "This file is not a Stocked kitchen backup." }
  sectionKeys.forEach { key -> root[key]?.let { require(it is JsonArray) { "$key must be an array." } } }
  val warnings = mutableListOf<String>()
  fun <T> rows(primary: String, alternate: String, decode: (JsonObject)->T): List<T> {
   val value = root[primary] ?: root[alternate] ?: return emptyList()
   require(value is JsonArray && value.size <= 10000) { "$primary must contain at most 10,000 records." }
   return value.mapIndexed { index, row ->
    require(row is JsonObject) { "$primary row ${index+1} is invalid." }
    decode(row)
   }
  }
  fun id(obj: JsonObject): JsonObject {
   val supplied = obj["id"]?.jsonPrimitive?.contentOrNull
   if (supplied != null) { require(runCatching { UUID.fromString(supplied) }.isSuccess) { "Record ID is invalid." }; return obj }
   warnings += "A record had no ID; a new stable ID was assigned."
   return JsonObject(obj + ("id" to JsonPrimitive(UUID.randomUUID().toString())))
  }
  fun normalize(obj: JsonObject, date: Boolean=false): JsonObject {
   var result=id(obj)
   if(date) {
    val value=result["expirationDate"]
    if(value is JsonPrimitive && !value.isString) {
     val seconds=value.doubleOrNull ?: error("Invalid expiration date.")
     require(seconds.isFinite() && seconds in -62135596800.0..253402300799.0)
     result=JsonObject(result + ("expirationDate" to JsonPrimitive(Instant.ofEpochSecond(kotlin.math.floor(seconds+978307200).toLong()).atZone(ZoneId.systemDefault()).toLocalDate().toString())))
    } else if(value is JsonPrimitive && value.isString && value.content.length > 10) {
     result=JsonObject(result + ("expirationDate" to JsonPrimitive(Instant.parse(value.content).atZone(ZoneId.systemDefault()).toLocalDate().toString())))
    }
   }
   return result
  }
  inlineExtraCheck(root)
  val inventory=rows("inventoryItems","inventory") { original -> val obj=normalize(original,true); json.decodeFromJsonElement<InventoryItem>(obj).copy(extra=JsonObject(unknown<InventoryItem>(obj) + original.filterKeys { it == "expirationDate" })).also(KitchenRules::validate) }
  val grocery=rows("groceryItems","grocery") { original -> val obj=normalize(original); json.decodeFromJsonElement<GroceryItem>(obj).copy(extra=unknown<GroceryItem>(obj)).also(KitchenRules::validate) }
  val recipes=rows("userRecipes","recipes") { original -> val obj=normalize(original); json.decodeFromJsonElement<Recipe>(obj).let { recipe -> recipe.copy(extra=unknown<Recipe>(obj), ingredients=recipe.ingredients.mapIndexed { i, ingredient -> ingredient.copy(extra=unknown<Ingredient>((obj["ingredients"] as? JsonArray)?.get(i)?.jsonObject ?: JsonObject(emptyMap()))) }) }.also(KitchenRules::validate) }
  val meals=rows("plannedMeals","planned") { original -> val obj=normalize(original); json.decodeFromJsonElement<PlannedMeal>(obj).copy(extra=unknown<PlannedMeal>(obj)).also(KitchenRules::validate) }
  fun unique(ids: List<String>) { require(ids.distinct().size == ids.size) { "Backup contains duplicate IDs. Review it before importing." } }
  unique(inventory.map{it.id}); unique(grocery.map{it.id}); unique(recipes.map{it.id}); unique(meals.map{it.id})
  val known=setOf("schemaVersion","inventory","inventoryItems","grocery","groceryItems","userRecipes","recipes","planned","plannedMeals","extra")
  val extras=((root["extra"] as? JsonObject)?.toMap().orEmpty()+root.filterKeys{it !in known}).filterKeys{it!="_androidHousehold"}
  val incoming=KitchenState(inventory=inventory,grocery=grocery,userRecipes=recipes,planned=meals,extra=JsonObject(extras))
  val conflicts=mutableListOf<String>()
  inventory.forEach { a->current.inventory.find{it.id==a.id}?.let{if(it!=a)conflicts += "Inventory: ${a.name}"} }
  grocery.forEach { a->current.grocery.find{it.id==a.id}?.let{if(it!=a)conflicts += "Grocery: ${a.name}"} }
  recipes.forEach { a->current.userRecipes.find{it.id==a.id}?.let{if(it!=a)conflicts += "Recipe: ${a.title}"} }
  meals.forEach { a->current.planned.find{it.id==a.id}?.let{if(it!=a)conflicts += "Meal: ${a.title}"} }
  if(extras.isNotEmpty()) warnings += "Additional iOS sections are preserved for export but are not editable in this Android build."
  return ImportPreview(incoming,conflicts,warnings.distinct())
 }
 private fun inlineExtraCheck(root:JsonObject) { require(root.size <= 100) { "Too many backup sections." } }
 private inline fun <reified T> unknown(obj: JsonObject): JsonObject {
  val keys=json.serializersModule.serializer<T>().descriptor.let { d->(0 until d.elementsCount).map{d.getElementName(it)}.toSet() }
  return JsonObject((obj["extra"] as? JsonObject)?.toMap().orEmpty()+obj.filterKeys{it !in keys})
 }
 private inline fun <reified T> wire(value:T):JsonObject {
  val obj=json.encodeToJsonElement(value).jsonObject
  return JsonObject((obj["extra"] as? JsonObject)?.toMap().orEmpty()+obj.filterKeys{it!="extra"})
 }
 // Foundation Date wire values are seconds since 2001, unlike sync updatedAt.
 private fun dateWire(value: JsonElement): JsonPrimitive {
  require(value is JsonPrimitive) { "Invalid backup date." }
  if (!value.isString) {
   val seconds = value.doubleOrNull ?: error("Invalid backup date.")
   require(seconds.isFinite()) { "Invalid backup date." }
   return value
  }
  val instant = if(value.content.length == 10) LocalDate.parse(value.content).atStartOfDay().toInstant(ZoneOffset.UTC) else Instant.parse(value.content)
  return JsonPrimitive(instant.epochSecond - 978307200 + instant.nano / 1_000_000_000.0)
 }
 // A date-only expiry is a calendar choice, like the native DatePicker.
 // Resolve its midnight in the local timezone; supplied instants stay exact.
 private fun expirationWire(value: JsonElement): JsonPrimitive {
  if (value is JsonPrimitive && value.isString && value.content.length == 10) {
   val instant = LocalDate.parse(value.content).atStartOfDay(ZoneId.systemDefault()).toInstant()
   return JsonPrimitive(instant.epochSecond - 978307200 + instant.nano / 1_000_000_000.0)
  }
  return dateWire(value)
 }
 private fun dateDay(value: JsonElement): String {
  val seconds = expirationWire(value).double
  val epoch = seconds + 978307200
  return Instant.ofEpochSecond(kotlin.math.floor(epoch).toLong()).atZone(ZoneId.systemDefault()).toLocalDate().toString()
 }
 fun export(state:KitchenState):String {
  val root=state.extra.filterKeys{it!="_androidHousehold" && it !in setOf("inventory", "grocery", "planned", "recipes")}.toMutableMap()
  root["schemaVersion"]=JsonPrimitive(3)
  root["exportedAt"]=JsonPrimitive(Instant.now().toString())
  root.putIfAbsent("displayName", JsonPrimitive("My Kitchen"))
  root.putIfAbsent("pastMeals", JsonArray(emptyList()))
  root.putIfAbsent("savedRecipes", JsonArray(emptyList()))
  root["inventoryItems"]=JsonArray(state.inventory.map{item->
   val obj=wire(item).toMutableMap()
   if(item.expirationDate == null) obj.remove("expirationDate") else {
    val original = item.extra["expirationDate"]
    obj["expirationDate"] = if(original != null && original !is JsonNull && dateDay(original) == item.expirationDate) expirationWire(original) else expirationWire(JsonPrimitive(item.expirationDate))
   }
   JsonObject(obj)
  })
  root["groceryItems"]=JsonArray(state.grocery.map{wire(it)})
  root["userRecipes"]=JsonArray(state.userRecipes.map{recipe ->
   val obj=wire(recipe).toMutableMap()
   obj.putIfAbsent("difficulty", JsonPrimitive("Medium"))
   obj.putIfAbsent("dishRole", JsonPrimitive("unspecified"))
   // Unknown original creation time stays absent on the wire. iOS assigns its
   // local adoption time when it constructs that record, not an invented past
   // source date. Present dates (including malformed/null values) are validated.
   obj["dateCreated"]?.let { obj["dateCreated"] = dateWire(it) }
   obj["lastCooked"]?.let { if(it !is JsonNull) obj["lastCooked"] = dateWire(it) }
   obj["ingredients"] = JsonArray(recipe.ingredients.map { ingredient ->
    val fields = wire(ingredient).toMutableMap()
    fields.putIfAbsent("isOptional", JsonPrimitive(false))
    JsonObject(fields)
   })
   JsonObject(obj)
  })
  root["plannedMeals"]=JsonArray(state.planned.map{
   val obj=wire(it).toMutableMap()
   obj.putIfAbsent("isBuilding", JsonPrimitive(false))
   obj.putIfAbsent("cookAheadStatus", JsonPrimitive("none"))
   JsonObject(obj)
  })
  return JsonObject(root).toString()
 }
 fun merge(existing:KitchenState, incoming:KitchenState, replaceExisting:Boolean):KitchenState {
  fun <T> combine(old:List<T>, new:List<T>, id:(T)->String):List<T> {
   val result=old.associateBy(id).toMutableMap()
   new.forEach { if(replaceExisting || !result.containsKey(id(it)))result[id(it)]=it }
   return result.values.toList()
  }
  return existing.copy(inventory=combine(existing.inventory,incoming.inventory){it.id},grocery=combine(existing.grocery,incoming.grocery){it.id},userRecipes=combine(existing.userRecipes,incoming.userRecipes){it.id},planned=combine(existing.planned,incoming.planned){it.id},extra=JsonObject(incoming.extra+existing.extra))
 }
}
