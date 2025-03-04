// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol_generated.dart';
import 'package:analysis_server/lsp_protocol/protocol_special.dart';
import 'package:analysis_server/src/computer/computer_color.dart'
    show ColorComputer, ColorReference;
import 'package:analysis_server/src/lsp/handlers/handlers.dart';
import 'package:analysis_server/src/lsp/mapping.dart';
import 'package:analyzer/dart/analysis/results.dart';

/// Handles textDocument/documentColor requests.
///
/// This request is sent by the client to the server to request the locations
/// of any colors in the document so that it can render color previews. If the
/// editor has a color picker, it may also call textDocument/colorPresentation
/// to obtain the code to insert when a new color is selected (see
/// [DocumentColorPresentationHandler]).
class DocumentColorHandler
    extends MessageHandler<DocumentColorParams, List<ColorInformation>> {
  DocumentColorHandler(super.server);
  @override
  Method get handlesMessage => Method.textDocument_documentColor;

  @override
  LspJsonHandler<DocumentColorParams> get jsonHandler =>
      DocumentColorParams.jsonHandler;

  @override
  Future<ErrorOr<List<ColorInformation>>> handle(
      DocumentColorParams params, CancellationToken token) async {
    if (!isDartDocument(params.textDocument)) {
      return success([]);
    }

    final path = pathOfDoc(params.textDocument);
    final unit = await path.mapResult(requireResolvedUnit);
    return unit.mapResult((unit) => _getColors(unit));
  }

  ErrorOr<List<ColorInformation>> _getColors(ResolvedUnitResult unit) {
    ColorInformation _toColorInformation(ColorReference reference) {
      return ColorInformation(
        range: toRange(unit.lineInfo, reference.offset, reference.length),
        color: Color(
          // LSP colors are decimal in the range 0-1 but our internal references
          // are 0-255, so divide them.
          alpha: reference.color.alpha / 255,
          red: reference.color.red / 255,
          green: reference.color.green / 255,
          blue: reference.color.blue / 255,
        ),
      );
    }

    final computer = ColorComputer(unit);
    final colors = computer.compute();
    return success(colors.map(_toColorInformation).toList());
  }
}
