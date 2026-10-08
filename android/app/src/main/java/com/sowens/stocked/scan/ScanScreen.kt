package com.sowens.stocked.scan

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.sowens.stocked.data.*
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

private suspend fun <T> Task<T>.result():T = suspendCoroutine { continuation ->
 addOnSuccessListener { continuation.resume(it) }
 addOnFailureListener { continuation.resumeWithException(it) }
}
private data class ScanResult(val text:String,val codes:List<String>)
private suspend fun scanImage(context:Context,uri:Uri):ScanResult = withContext(Dispatchers.IO) {
 val bytes=context.contentResolver.openInputStream(uri)?.use { input ->
  val out=java.io.ByteArrayOutputStream();val buf=ByteArray(8192)
  while(true){val n=input.read(buf);if(n<0)break;require(out.size()+n<=20*1024*1024){"Photo exceeds 20 MB"};out.write(buf,0,n)};out.toByteArray()
 } ?: error("Photo could not be opened")
 val bounds=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
 require(bounds.outWidth>0 && bounds.outHeight>0 && bounds.outWidth.toLong()*bounds.outHeight<=100_000_000){"Choose a supported photo smaller than 100 megapixels"}
 var sample=1;while(maxOf(bounds.outWidth,bounds.outHeight)/sample>2400)sample*=2
 val bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.size,BitmapFactory.Options().apply{inSampleSize=sample}) ?: error("Photo could not be decoded")
 val rotation=when(runCatching{ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION,1)}.getOrDefault(1)){6->90;3->180;8->270;else->0}
 val image=InputImage.fromBitmap(bitmap,rotation)
 val recognizer=TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
 val barcode=BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_EAN_13,Barcode.FORMAT_EAN_8,Barcode.FORMAT_UPC_A,Barcode.FORMAT_UPC_E).build())
 try { ScanResult(recognizer.process(image).result().text,barcode.process(image).result().mapNotNull{it.rawValue}.distinct()) }
 finally{recognizer.close();barcode.close();bitmap.recycle()}
}
private suspend fun lookup(code:String):String = withContext(Dispatchers.IO) {
 require(code.matches(Regex("[0-9]{8,14}"))){"Enter a numeric product barcode"}
 val connection=URL("https://world.openfoodfacts.org/api/v2/product/$code.json?fields=product_name,brands").openConnection() as HttpsURLConnection
 connection.connectTimeout=10_000;connection.readTimeout=10_000;connection.instanceFollowRedirects=false
 connection.setRequestProperty("User-Agent","StockedAndroid/0.1 (https://sowensstudios.com/support/)")
 try{ require(connection.responseCode==200){"Product lookup unavailable. Enter its name manually."}
  val bytes=connection.inputStream.use{ input -> val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(8192);while(true){val n=input.read(buffer);if(n<0)break;require(out.size()+n<=256*1024){"Product response exceeds safe limit"};out.write(buffer,0,n)};out.toByteArray()};require(bytes.size<=256*1024){"Product response exceeds safe limit"}
  JSONObject(String(bytes,Charsets.UTF_8)).optJSONObject("product")?.optString("product_name")?.takeIf{it.isNotBlank()} ?: error("Product not found. Enter its name manually.")
 }finally{connection.disconnect()}
}

@Composable
fun ScanScreen(repository:KitchenRepository, report:(String)->Unit, onClose:()->Unit) {
 val context=LocalContext.current;val scope=rememberCoroutineScope()
 var busy by remember{mutableStateOf(false)};var text by remember{mutableStateOf("")};var code by remember{mutableStateOf("")};var name by remember{mutableStateOf("")};var message by remember{mutableStateOf<String?>(null)}
 var imageURI by remember{mutableStateOf<Uri?>(null)}
 var reviewed by remember{mutableStateOf(false)}
 fun read(uri:Uri){scope.launch{busy=true;message=null;try{val result=scanImage(context,uri);text=result.text;code=result.codes.firstOrNull().orEmpty();reviewed=false;message=if(text.isBlank()&&code.isBlank())"No text or barcode found. Try a brighter, sharper photo or enter items manually." else "Review extracted text before saving."}catch(e:Exception){message=e.message ?: "Scan failed"}finally{busy=false}}}
 val photo=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){it?.let(::read)}
 val camera=rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()){ok->if(ok)imageURI?.let(::read)}
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
  Text("Scan products and receipts",style=MaterialTheme.typography.headlineSmall)
  Text("Text and barcodes are read on this device. Product lookup sends only the barcode to Open Food Facts.")
  Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
   OutlinedButton(enabled=!busy,onClick={photo.launch(arrayOf("image/*"))}){Text("Choose photo")}
   OutlinedButton(enabled=!busy,onClick={try{val dir=File(context.cacheDir,"scan").apply{mkdirs()};dir.listFiles()?.forEach{if(it.lastModified()<System.currentTimeMillis()-86400000)it.delete()};val file=File.createTempFile("capture-",".jpg",dir);imageURI=FileProvider.getUriForFile(context,context.packageName+".files",file);camera.launch(imageURI!!)}catch(e:Exception){message="Camera unavailable. Choose a photo instead."}}){Text("Take photo")}
  }
  if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
  message?.let{Text(it)}
  OutlinedTextField(code,{code=it},label={Text("Product barcode")},modifier=Modifier.fillMaxWidth(),singleLine=true)
  OutlinedButton(enabled=!busy&&code.isNotBlank(),onClick={scope.launch{busy=true;try{name=lookup(code);message="Product name from Open Food Facts (ODbL). Review before saving."}catch(e:Exception){message=e.message}finally{busy=false}}}){Text("Look up product")}
  OutlinedTextField(name,{name=it},label={Text("Product name")},modifier=Modifier.fillMaxWidth())
  Button(enabled=!busy&&name.isNotBlank(),onClick={scope.launch{busy=true;try{repository.upsertInventory(InventoryItem(name=name.trim(),barcode=code.takeIf{it.isNotBlank()}));name="";message="Product saved";report("Product added to inventory")}catch(e:Exception){message=e.message}finally{busy=false}}}){Text("Add product")}
  HorizontalDivider()
  Text("Receipt review",style=MaterialTheme.typography.titleMedium)
  Text("Edit this to one item name per line. Remove totals, prices, addresses and other receipt text. Each line will add one item; adjust quantities in Inventory.")
  OutlinedTextField(text,{text=it;reviewed=false},label={Text("Reviewed item names")},modifier=Modifier.fillMaxWidth(),minLines=5,maxLines=12)
  Row{Checkbox(reviewed,{reviewed=it});Text("I reviewed these names and quantities")}
  Button(enabled=!busy&&reviewed&&text.isNotBlank(),onClick={scope.launch{busy=true;try{val rows=text.lines().map{it.trim()}.filter{it.isNotEmpty()};require(rows.size<=200){"Review at most 200 items at a time"};val items=rows.map{InventoryItem(name=it,updatedAt=System.currentTimeMillis().toDouble())};items.forEach(KitchenRules::validate);repository.addInventoryBatch(items);text="";reviewed=false;message="${items.size} items added";report("Receipt items added")}catch(e:Exception){message=e.message}finally{busy=false}}}){Text("Save reviewed items")}
  OutlinedButton(onClick=onClose,enabled=!busy){Text("Close")}
 }
}
