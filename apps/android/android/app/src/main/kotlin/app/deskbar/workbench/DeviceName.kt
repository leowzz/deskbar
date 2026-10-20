package app.deskbar.workbench

internal fun deviceName(manufacturer: String?, model: String?): String {
    fun clean(value: String?) = value?.trim()?.takeUnless {
        it.isEmpty() || it.equals("unknown", ignoreCase = true)
    }
    val brand = clean(manufacturer)
    val product = clean(model) ?: return "Android 工作台"
    return (if (brand == null || product.startsWith(brand, ignoreCase = true)) {
        product
    } else {
        "$brand $product"
    }).take(64)
}
