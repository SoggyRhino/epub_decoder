/// Allowed special uses of resources in EPUB3.
enum ItemProperty {
  coverImage('cover-image'),
  mathML('mathml'),
  scripted('scripted'),
  svg('svg'),
  remoteResources('remote-resources'),
  $switch('switch'),
  nav('nav'),
  unSupported('unsupported');

  const ItemProperty(this.value);
  final String value;

  static ItemProperty fromValue(String value) {
    return ItemProperty.values.firstWhere((item) => item.value == value,
        orElse: () => unSupported);
  }
}
