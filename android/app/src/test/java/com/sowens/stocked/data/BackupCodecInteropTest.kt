package com.sowens.stocked.data

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class BackupCodecInteropTest {
 private fun numericValue(value: JsonElement): JsonElement = when (value) {
  is JsonObject -> JsonObject(value.mapValues { numericValue(it.value) })
  is JsonArray -> JsonArray(value.map(::numericValue))
  is JsonPrimitive -> if (!value.isString && value.doubleOrNull != null)
   BackupCodec.json.parseToJsonElement(java.math.BigDecimal(value.content).stripTrailingZeros().toPlainString()) else value
 }

 private fun fixture(name: String): String = javaClass.getResource("/backup/$name")!!.readText()
 @Test fun actualIosModelsRoundTripThroughCanonicalAndroidExport() {
  val incoming = BackupCodec.preview(fixture("ios-canonical.json"), KitchenState()).incoming
  val actual = BackupCodec.json.parseToJsonElement(BackupCodec.export(incoming)).jsonObject
  val golden = BackupCodec.json.parseToJsonElement(fixture("android-canonical.json")).jsonObject
  assertEquals(numericValue(JsonObject(golden.filterKeys { it != "exportedAt" })), numericValue(JsonObject(actual.filterKeys { it != "exportedAt" })))
  assertFalse(actual.containsKey("inventory")); assertFalse(actual.containsKey("grocery")); assertFalse(actual.containsKey("planned"))
  assertEquals(3, actual["schemaVersion"]!!.jsonPrimitive.int)
  assertEquals(800000000.125, actual["inventoryItems"]!!.jsonArray.single().jsonObject["expirationDate"]!!.jsonPrimitive.double, 0.0)
  assertEquals(1770000000123.0, actual["inventoryItems"]!!.jsonArray.single().jsonObject["updatedAt"]!!.jsonPrimitive.double, 0.0)
  val again = BackupCodec.preview(actual.toString(), KitchenState()).incoming
  assertEquals(numericValue(BackupCodec.json.encodeToJsonElement(incoming.inventory)), numericValue(BackupCodec.json.encodeToJsonElement(again.inventory)))
  assertEquals(numericValue(BackupCodec.json.encodeToJsonElement(incoming.grocery)), numericValue(BackupCodec.json.encodeToJsonElement(again.grocery)))
  assertEquals(numericValue(BackupCodec.json.encodeToJsonElement(incoming.userRecipes)), numericValue(BackupCodec.json.encodeToJsonElement(again.userRecipes)))
  assertEquals(numericValue(BackupCodec.json.encodeToJsonElement(incoming.planned)), numericValue(BackupCodec.json.encodeToJsonElement(again.planned)))
 }
 @Test fun legacyAndroidStillImportsWithoutRenamingOrDroppingIds() {
  val text = """{"inventory":[{"id":"00000000-0000-0000-0000-000000000001","name":"Milk","quantity":3,"expirationDate":"2026-10-22"}],"grocery":[],"planned":[],"userRecipes":[],"futureSection":{"keep":true}}"""
  val incoming = BackupCodec.preview(text, KitchenState()).incoming
  assertEquals("00000000-0000-0000-0000-000000000001", incoming.inventory.single().id)
  assertEquals(3, incoming.inventory.single().quantity)
  val exported = BackupCodec.json.parseToJsonElement(BackupCodec.export(incoming)).jsonObject
  assertEquals(JsonObject(mapOf("keep" to JsonPrimitive(true))), exported["futureSection"])
 }
 @Test fun unknownAndMalformedSectionsRefusedButExplicitEmptyAccepted() {
  for (text in listOf("{}", """{"unrelated":[]}""", """{"inventoryItems":null}""", """{"inventoryItems":{}}""", """{"inventoryItems":[1]}""")) {
   assertTrue(text, runCatching { BackupCodec.preview(text, KitchenState()) }.isFailure)
  }
  assertTrue(BackupCodec.preview("""{"inventoryItems":[],"groceryItems":[]}""", KitchenState()).incoming.inventory.isEmpty())
 }
 @Test fun freshAndLegacyRecipesExportWithoutFabricatingCreationDate() {
  val recipe = Recipe(id = "00000000-0000-0000-0000-000000000006", title = "Fresh pudding", ingredients = listOf(Ingredient(id = "00000000-0000-0000-0000-000000000007", name = "Milk", amount = "1 cup")))
  val fresh = BackupCodec.json.parseToJsonElement(BackupCodec.export(KitchenState(userRecipes = listOf(recipe)))).jsonObject
  val row = fresh["userRecipes"]!!.jsonArray.single().jsonObject
  assertEquals(recipe.id, row["id"]!!.jsonPrimitive.content)
  assertFalse(row.containsKey("dateCreated"))
  val imported = BackupCodec.preview("""{"userRecipes":[{"id":"${recipe.id}","title":"Legacy Android recipe"}]}""", KitchenState()).incoming
  val legacy = BackupCodec.json.parseToJsonElement(BackupCodec.export(imported)).jsonObject
  assertFalse(legacy["userRecipes"]!!.jsonArray.single().jsonObject.containsKey("dateCreated"))
 }
 @Test fun malformedKnownRecipeDatesAreNeverTreatedAsMissing() {
  for (date in listOf(JsonPrimitive("not-a-date"), JsonNull)) {
   val recipe = Recipe(title = "Bad date", extra = JsonObject(mapOf("dateCreated" to date)))
   assertTrue(runCatching { BackupCodec.export(KitchenState(userRecipes = listOf(recipe))) }.isFailure)
  }
 }
 @Test fun dateOnlyExpirationUsesLocalCalendarWithoutChangingKnownInstants() {
  val previous = java.util.TimeZone.getDefault()
  try {
   for (zone in listOf("America/Chicago", "UTC")) {
    java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone(zone))
    val row = InventoryItem(id = "00000000-0000-0000-0000-000000000010", name = "Fresh milk", quantity = 2, expirationDate = "2026-10-22", updatedAt = 1770000000123.0)
    val root = BackupCodec.json.parseToJsonElement(BackupCodec.export(KitchenState(inventory = listOf(row)))).jsonObject
    val exported = root["inventoryItems"]!!.jsonArray.single().jsonObject
    val expected = java.time.LocalDate.parse("2026-10-22").atStartOfDay(java.time.ZoneId.of(zone)).toInstant().epochSecond - 978307200
    assertEquals(expected.toDouble(), exported["expirationDate"]!!.jsonPrimitive.double, 0.0)
    assertEquals(row.expirationDate, BackupCodec.preview(root.toString(), KitchenState()).incoming.inventory.single().expirationDate)
    assertEquals(row.updatedAt, exported["updatedAt"]!!.jsonPrimitive.double, 0.0)
    val known = BackupCodec.preview(fixture("ios-canonical.json"), KitchenState()).incoming
    val knownRoot = BackupCodec.json.parseToJsonElement(BackupCodec.export(known)).jsonObject
    assertEquals(800000000.125, knownRoot["inventoryItems"]!!.jsonArray.single().jsonObject["expirationDate"]!!.jsonPrimitive.double, 0.0)
    val edited = known.inventory.single().copy(expirationDate = "2026-10-22")
    val editedRoot = BackupCodec.json.parseToJsonElement(BackupCodec.export(known.copy(inventory = listOf(edited)))).jsonObject
    assertEquals(expected.toDouble(), editedRoot["inventoryItems"]!!.jsonArray.single().jsonObject["expirationDate"]!!.jsonPrimitive.double, 0.0)

    val iso = BackupCodec.preview("""{"inventoryItems":[{"name":"Instant milk","expirationDate":"2026-10-22T00:00:00.125Z"}]}""", KitchenState()).incoming
    val isoRoot = BackupCodec.json.parseToJsonElement(BackupCodec.export(iso)).jsonObject
    assertEquals(java.time.Instant.parse("2026-10-22T00:00:00.125Z").epochSecond - 978307200 + 0.125, isoRoot["inventoryItems"]!!.jsonArray.single().jsonObject["expirationDate"]!!.jsonPrimitive.double, 0.0)
   }
  } finally { java.util.TimeZone.setDefault(previous) }
 }

}
