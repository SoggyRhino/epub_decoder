import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';
import 'package:archive/archive.dart';
import 'package:epub_decoder/models/models.dart';
import 'package:epub_decoder/standar_constants.dart';

/// Representation of an EPUB file.
///
/// This class provides methods to parse an EPUB file from bytes or from a file,
/// and access its metadata, manifest items, and spine through [Section]s.
class Epub extends Equatable {
  /// Constructs an [Epub] instance from a list of bytes.
  ///
  /// The [fileBytes] parameter should contain the raw bytes of the EPUB file.
  Epub.fromBytes(Uint8List fileBytes)
      : zip = ZipDecoder().decodeBytes(fileBytes) {
    _metadata = Lazy(_initializeMetadata);
    _items = Lazy(_initializeItems);
    _sections = Lazy(_initializeSections);
    _navigation = Lazy(_initializeNavigation);
    _rootFilePath = Lazy(_initializeRootFilePath);
    _baseDirectory = Lazy(_initializeBaseDirectory);
  }

  /// Constructs an [Epub] instance from a [File].
  ///
  /// The [file] parameter should point to a valid EPUB file.
  Epub.fromFile(File file)
      : assert(file.path._extension == 'epub'),
        zip = ZipDecoder().decodeBytes(file.readAsBytesSync()) {
    _metadata = Lazy(_initializeMetadata);
    _items = Lazy(_initializeItems);
    _sections = Lazy(_initializeSections);
    _navigation = Lazy(_initializeNavigation);
    _rootFilePath = Lazy(_initializeRootFilePath);
    _baseDirectory = Lazy(_initializeBaseDirectory);
  }

  /// The decoded ZIP archive of the EPUB file.
  final Archive zip;

  late final Lazy<List<Metadata>> _metadata;
  late final Lazy<List<Item>> _items;
  late final Lazy<List<Section>> _sections;
  late final Lazy<List<Section>> _navigation;
  late final Lazy<String> _rootFilePath;
  late final Lazy<String> _baseDirectory;

  String get title =>
      metadata
          .firstWhere(
              (element) =>
                  element is DublinCoreMetadata && element.key == 'title',
              orElse: () => Metadata.empty)
          .value ??
      '';

  List<String> get authors => metadata
      .where((element) =>
          element is DublinCoreMetadata && element.key == 'creator')
      .map((element) => element.value ?? '')
      .toList();

  Item? get cover {
    Item? cover = items.firstWhereOrNull(
        (element) => element.properties.contains(ItemProperty.coverImage));

    //check if cover is defined in a different way (valid in epub 2 spec)
    if (cover == null) {
      final coverMeta = metadata.firstWhereOrNull(
          (element) => element is DocumentMetadata && element.name == 'cover');
      if (coverMeta != null) {
        cover =
            items.firstWhereOrNull((element) => element.id == coverMeta.value);
      }
    }

    return cover;
  }

  String get baseDirectory => _baseDirectory.value;

  String _initializeBaseDirectory() {
    return File(rootFilePath).parent.path;
  }

  /// Path to the root file (usually 'content.opf') in the EPUB.
  ///
  /// Throws a [FormatException] if the container file or the root file path
  /// is not found.
  String get rootFilePath => _rootFilePath.value;

  String _initializeRootFilePath() {
    final container = zip.findFile(containerFilePath);
    container ?? (throw const FormatException('Container file not found.'));

    final content = XmlDocument.parse(utf8.decode(container.content));
    final path = content.rootElement
        .xpath(
            '/*[local-name() = "container"]/*[local-name() = "rootfiles"]/*[local-name() = "rootfile"]')
        .first
        .getAttribute('full-path');

    path ?? (throw const FormatException('full-path attribute not found.'));
    return path;
  }

  /// Content of the root file as an XML document.
  ///
  /// Throws a [FormatException] if the root file is not found.
  XmlDocument get _rootFileContent {
    final file = zip.findFile(rootFilePath);
    file ?? (throw const FormatException('Root file not found.'));
    final content = XmlDocument.parse(utf8.decode(file.content));
    return content;
  }

  /// Metadata of the EPUB file, such as title, authors, media overlays, etc.
  ///
  /// This includes both Dublin Core metadata and additional document metadata.
  /// If the metadata has already been parsed, returns the cached metadata.
  List<Metadata> get metadata => _metadata.value;

  List<Metadata> _initializeMetadata() {
    final metadata = <Metadata>[];
    final metadataxml = _rootFileContent
        .xpath('/*[local-name() = "package"]/*[local-name() = "metadata"]')
        .first;

    for (var element in metadataxml.descendantElements) {
      if (element.namespacePrefix == 'dc') {
        metadata.add(DublinCoreMetadata.fromXmlElement(element));
        continue;
      }

      if (element.localName.toString() == 'meta') {
        final docmetadata = DocumentMetadata.fromXmlElement(element);

        if (docmetadata.refinesTo == null) {
          metadata.add(docmetadata);
        } else {
          final target = metadata.firstWhere(
            (metaelement) => docmetadata.refinesTo == metaelement.id,
            orElse: () => Metadata.empty,
          );

          if (target.isEmpty) {
            metadata.add(docmetadata);
          } else {
            target.refinements.add(docmetadata);
          }
        }
      }
    }

    return metadata;
  }

  /// Resources (images, audio, text, etc.) of the EPUB file, as [Item]s.
  ///
  /// If the items have already been parsed, returns the cached items.
  List<Item> get items => _items.value;

  List<Item> _initializeItems() {
    final items = <Item>[];
    final itemsxml = _rootFileContent
        .xpath('/*[local-name() = "package"]/*[local-name() = "manifest"]')
        .first;

    for (var element in itemsxml.descendantElements) {
      final mediaOverlayId = element.getAttribute('media-overlay');
      Item? item;

      if (mediaOverlayId != null) {
        final mediaOverlay = itemsxml.descendantElements.firstWhere(
          (itemxml) => itemxml.getAttribute('id') == mediaOverlayId,
          orElse: () => throw UnimplementedError(
              'Media overlay with id $mediaOverlayId not found or not declared.'),
        );

        try {
          item = Item.fromXmlElement(
            element,
            source: this,
            mediaOverlay: Item.fromXmlElement(mediaOverlay, source: this),
          );
        } catch (e) {
          print('Error parsing item with id ${element.getAttribute('id')}');
        }
      } else {
        try {
          item = Item.fromXmlElement(element, source: this);
        } catch (e) {
          print('Error parsing item with id ${element.getAttribute('id')}');
        }
      }

      if (item != null) {
        item._addRefinementsFrom(metadata);
        item.mediaOverlay?._addRefinementsFrom(metadata);
        items.add(item);
      }
    }

    return items;
  }

  /// Reading sections of the EPUB file in order.
  ///
  /// Sections are determined by the spine element in the EPUB's package document.
  /// If the sections have already been parsed, returns the cached sections.
  List<Section> get sections => _sections.value;

  List<Section> _initializeSections() {
    final sections = <Section>[];
    final spinexml = _rootFileContent
        .xpath('/*[local-name() = "package"]/*[local-name() = "spine"]')
        .first;
    final spineItems = spinexml.findAllElements('itemref', namespace: '*');
    for (var (index, itemref) in spineItems.indexed) {
      final item = items.firstWhereOrNull(
        (item) => item.id == itemref.getAttribute('idref'),
      );
      if (item == null) continue;

      final section = Section(
        content: item,
        source: this,
        readingOrder: index + 1,
        linear: (itemref.getAttribute("linear") ?? "") == "yes",
      );

      sections.add(section);
    }

    return sections;
  }

  List<Section> get navigation => _navigation.value;

  /// Sections will be parsed in the following order:
  ///  - Navigation document (epub 3.0)
  ///  - NCX Toc (epub 2.0)
  ///  - Spine skipping nonlinear and navigation sections (final option)
  List<Section> _initializeNavigation() {
    final hrefMap =
        items.asMap().map((key, value) => MapEntry(value.href, value));

    // Attempt 1 - navigation document
    final nav = items
        .skipWhile((item) => !item.properties.contains(ItemProperty.nav))
        .map((item) => XmlDocument.parse(utf8.decode(item.fileContent)))
        .map((document) =>
            document.xpath('/*[local-name() = "nav"]').firstOrNull)
        .nonNulls
        .firstWhereOrNull((nav) => nav.getAttribute('epub:type') == 'toc');

    if (nav != null) {
      final sections = <Section>[];

      int readingOrder = 1;

      final lists = nav.findAllElements('li');

      for (final list in lists) {
        final link = list.findElements('a').first;
        final href = link.getAttribute('href');

        if (href == null) continue;
        final title = link.innerText;

        final item = hrefMap[href]!;

        final section = Section(
          content: item,
          source: this,
          readingOrder: readingOrder++,
          title: title,
          subSection: false,
        );

        sections.add(section);

        for (final subSection in list.findElements('a').skip(1)) {
          final subSectionHref = subSection.getAttribute('href');
          final subSectionTitle = subSection.innerText;

          if (subSectionHref == null || subSectionHref.contains('#')) {
            continue;
          }

          final subSectionItem = hrefMap[subSectionHref]!;

          final section = Section(
            content: subSectionItem,
            source: this,
            readingOrder: readingOrder++,
            title: subSectionTitle,
            subSection: true,
          );
          sections.add(section);
        }
      }
      return sections;
    }

    //Attempt 2 - separate toc document (epub 2 spec)
    final toc = _rootFileContent
        .xpath('/*[local-name() = "package"]/*[local-name() = "spine"]')
        .firstOrNull
        ?.getAttribute('toc');

    if (toc != null) {
      final item = items.firstWhereOrNull((item) => item.id == toc);

      if (item != null) {
        final document = XmlDocument.parse(utf8.decode(item.fileContent));
        final sections = <Section>[];

        int readingOrder = 1;

        final navMap = document.findAllElements('navMap').firstOrNull;
        if (navMap != null) {
          final navPoints = navMap.findElements('navPoint');

          for (final navPoint in navPoints) {
            final navLabel = navPoint.findElements('navLabel').firstOrNull;
            final content = navPoint.findElements('content').firstOrNull;

            if (navLabel != null && content != null) {
              final title = navLabel.findElements('text').first.innerText;
              final src = content.getAttribute('src');

              if (src != null) {
                final item = hrefMap[src.split('#').first];
                if (item != null) {
                  final section = Section(
                    content: item,
                    source: this,
                    readingOrder: readingOrder++,
                    title: title,
                  );
                  sections.add(section);
                }
              }
            }
          }
        }

        return sections;
      }
    }

    // Final option: skip nonlinear and navigation sections of the spine
    return sections
        .skipWhile(
            (section) => section.content.properties.contains(ItemProperty.nav))
        .skipWhile((section) => !section.linear)
        .toList()
        .indexed
        .map((entry) => Section(
            content: entry.$2.content,
            source: this,
            readingOrder: entry.$1 + 1))
        .toList();
  }

  /// The list of properties that are used to determine whether two instances are equal.
  ///
  /// props[0] = metadata, props[1] = items, props[2] = sections
  @override
  List<Object?> get props => [
        // zip,
        // _metadata.isInitialized ? _metadata.value : null,
        // _items.isInitialized ? _items.value : null,
        // _sections.isInitialized ? _sections.value : null,
        _metadata,
        _items,
        _sections
      ];
}

extension on String {
  String get _extension => split('.').last;
}

extension on Item {
  void _addRefinementsFrom(List<Metadata> metadata) {
    final docmetadata = metadata
        .where((element) =>
            element is DocumentMetadata &&
            element.refinesTo != null &&
            element.refinesTo == id)
        .map((element) => element as DocumentMetadata);
    refinements.addAll(docmetadata);
  }
}
