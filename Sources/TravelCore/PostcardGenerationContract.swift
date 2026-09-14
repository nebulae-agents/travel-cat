/// Requirements for newly generated artwork; stored legacy postcards are not revalidated.
public enum PostcardGenerationContract {
  public static let targetWidth = 1536
  public static let targetHeight = 1024
  public static let maximumAxis = 32768
  public static let maximumPixels = 100_000_000

  public static func accepts(width: Int, height: Int) -> Bool {
    // Bound operands before multiplication, including hostile metadata values.
    guard width >= 1152, height >= 768,
      width <= maximumAxis, height <= maximumAxis,
      width <= maximumPixels / height else { return false }
    return width * 2 == height * 3
  }

  public static let prompt = """
    Generate a 1536 x 1024 landscape travel postcard in exact 3:2 aspect ratio. Preserve the frozen pet identity and reference proportions. Show the entire pet, including ears, paws and tail, intact inside the frame with breathing room; never crop or stretch the pet. Keep the pet roughly 20-40% of the frame. Use no text, logo, watermark or decorative stamp. Reserve a calm, low-detail area away from the pet for a readable quote overlay.
    """
}
