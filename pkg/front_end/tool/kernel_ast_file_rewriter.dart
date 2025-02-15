// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:io" show File, Platform, stdout;
import "dart:typed_data" show Uint8List;

import 'package:_fe_analyzer_shared/src/parser/parser.dart'
    show IdentifierContext;

import 'package:_fe_analyzer_shared/src/scanner/token.dart'
    show CommentToken, Token;

import "package:front_end/src/util/parser_ast.dart";

import 'package:front_end/src/util/parser_ast_helper.dart';

void main(List<String> args) {
  Uri uri = Platform.script;
  uri = uri.resolve("../../kernel/lib/ast.dart");
  Uint8List bytes = new File.fromUri(uri).readAsBytesSync();
  CompilationUnitEnd ast =
      getAST(bytes, includeBody: true, includeComments: true);
  Map<String, TopLevelDeclarationEnd> classes = {};
  for (TopLevelDeclarationEnd cls in ast.getClasses()) {
    IdentifierHandle identifier = cls.getIdentifier();
    // TODO(srawlins): Look into fixing this code. Right now we get:
    // "The argument type 'Token' isn't related to 'String'."
    // ignore: collection_methods_unrelated_type
    assert(classes[identifier.token] == null);
    classes[identifier.token.toString()] = cls;
  }

  Set<String?> goodNames = {"TreeNode"};
  Map<Token, Replacement> replacements = {};
  for (MapEntry<String, TopLevelDeclarationEnd> entry in classes.entries) {
    TopLevelDeclarationEnd cls = entry.value;

    // Simple "class hierarchy" to only work on TreeNodes.
    if (goodNames.contains(entry.key)) {
      // Cached good.
    } else {
      // Check if good.
      String? parent = getExtends(cls);
      TopLevelDeclarationEnd? parentCls = classes[parent];
      List<String?> allParents = [parent];
      while (
          parent != null && parentCls != null && !goodNames.contains(parent)) {
        parent = getExtends(parentCls);
        allParents.add(parent);
        parentCls = classes[parent];
      }
      if (goodNames.contains(parent)) {
        goodNames.addAll(allParents);
      } else {
        continue;
      }
    }

    ClassDeclarationEnd classDeclaration = cls.getClassDeclaration();
    ClassOrMixinOrExtensionBodyEnd classOrMixinBody =
        classDeclaration.getClassOrMixinOrExtensionBody();

    Set<String> namedClassConstructors = {};
    Set<String> namedFields = {};
    for (MemberEnd member in classOrMixinBody.getMembers()) {
      if (member.isClassConstructor()) {
        ClassConstructorEnd constructor = member.getClassConstructor();
        Token nameToken = constructor.beginToken;
        // String name = nameToken.lexeme;
        if (nameToken.next!.lexeme == ".") {
          nameToken = nameToken.next!.next!;
          // name += ".$nameToken";
          namedClassConstructors.add(nameToken.lexeme);
        }
        if (nameToken.next!.lexeme == ".") {
          throw "Unexpected";
        }
      } else if (member.isClassFields()) {
        ClassFieldsEnd classFields = member.getClassFields();
        Token identifierToken = classFields.getFieldIdentifiers().single.token;
        String identifier = identifierToken.toString();
        namedFields.add(identifier);
      }
    }

    // If there isn't a `frozen` field in `TreeNode` we insert one.
    if (entry.key == "TreeNode" && !namedFields.contains("frozen")) {
      Token classBraceToken = classOrMixinBody.beginToken;
      assert(classBraceToken.lexeme == "{");
      replacements[classBraceToken] = new Replacement(
          classBraceToken, classBraceToken, "{\n  bool frozen = false;");
    }

    for (MemberEnd member in classOrMixinBody.getMembers()) {
      if (member.isClassConstructor()) {
        processConstructor(
            member, replacements, namedClassConstructors, namedFields);
      } else if (member.isClassFields()) {
        processField(member, entry, replacements);
      }
    }
  }
  Token? token = ast.getBegin().token;

  int endOfLast = token.end;
  while (token != null) {
    CommentToken? comment = token.precedingComments;
    while (comment != null) {
      if (comment.offset > endOfLast) {
        for (int i = endOfLast; i < comment.offset; i++) {
          int byte = bytes[i];
          stdout.writeCharCode(byte);
        }
      }

      stdout.write(comment.value());
      endOfLast = comment.end;
      comment = comment.next as CommentToken?;
    }

    if (token.isEof) break;
    if (token.offset > endOfLast) {
      for (int i = endOfLast; i < token.offset; i++) {
        int byte = bytes[i];
        stdout.writeCharCode(byte);
      }
    }

    Replacement? replacement = replacements[token];
    if (replacement != null) {
      stdout.write(replacement.replacement);
      token = replacement.endToken;
    } else {
      stdout.write(token.lexeme);
    }
    endOfLast = token.end;
    token = token.next;
  }
}

void processField(
    MemberEnd member,
    MapEntry<String, TopLevelDeclarationEnd> entry,
    Map<Token, Replacement> replacements) {
  ClassFieldsEnd classFields = member.getClassFields();

  if (classFields.count != 1) {
    throw "Notice ${classFields.count}";
  }

  Token identifierToken = classFields.getFieldIdentifiers().single.token;
  String identifier = identifierToken.toString();

  if (identifier == "frozen" && entry.key == "TreeNode") return;

  if (classFields.staticToken != null) {
    return;
  }
  bool isFinal = false;
  if (classFields.varFinalOrConst?.toString() == "final") {
    isFinal = true;
  }

  TypeHandle? type = classFields.getFirstType();
  String typeString = "dynamic";
  if (type != null) {
    Token token = type.beginToken;
    typeString = "";
    while (token != identifierToken) {
      typeString += " ${token.lexeme}";
      token = token.next!;
    }
    typeString = typeString.trim();
  }

  FieldInitializerEnd? initializer = classFields.getFieldInitializer();
  String initializerString = "";
  if (initializer != null) {
    Token token = initializer.assignment;
    Token endToken = initializer.endToken.next!;
    while (token != endToken) {
      initializerString += " ${token.lexeme}";
      token = token.next!;
    }
    initializerString = initializerString.trim();
  }

  Token beginToken = classFields.beginToken;
  Token endToken = classFields.endToken;

  String frozenCheckCode =
      """if (frozen) throw "Trying to modify frozen node!";""";

  if (identifier == "parent" && entry.key == "TreeNode") {
    // We update the parent for libraries for instance all the time (e.g.
    // when we link).
    frozenCheckCode = "";
  } else if (identifier == "transformerFlags" && entry.key == "Member") {
    // The verifier changes this for all libraries
    // (and then change it back again).
    frozenCheckCode = "";
  } else if (identifier == "initializer" && entry.key == "Field") {
    // The constant evaluator does some stuff here. Only allow that
    // when it's basically a no-op though!
    frozenCheckCode = """
    if (frozen) {
      if (_initializer is ConstantExpression && newValue is ConstantExpression) {
        if ((_initializer as ConstantExpression).constant == newValue.constant) {
          _initializer = newValue;
          return;
        }
      }
      throw "Trying to modify frozen node!";
    }""";
  }

  if (!isFinal) {
    replacements[beginToken] = new Replacement(beginToken, endToken, """
$typeString _$identifier$initializerString;
$typeString get $identifier => _$identifier;
void set $identifier($typeString newValue) {
    $frozenCheckCode
  _$identifier = newValue;
}""");
  } else {
    // Don't create setter for final field.
    // TODO: Possibly wrap a list for instance of a non-writable one.
    replacements[beginToken] = new Replacement(beginToken, endToken, """
final $typeString _$identifier$initializerString;
$typeString get $identifier => _$identifier;""");
  }
}

void processConstructor(MemberEnd member, Map<Token, Replacement> replacements,
    Set<String> namedClassConstructors, Set<String> namedFields) {
  ClassConstructorEnd constructor = member.getClassConstructor();
  FormalParametersEnd formalParameters = constructor.getFormalParameters();
  List<FormalParameterEnd> parameters = formalParameters.getFormalParameters();

  for (FormalParameterEnd parameter in parameters) {
    Token token = parameter.getBegin().token;
    if (token.lexeme != "this") {
      continue;
    }
    // Here `this.foo` can just be replace with `this._foo`.
    Token afterDot = token.next!.next!;
    replacements[afterDot] = new Replacement(afterDot, afterDot, "_$afterDot");
  }

  OptionalFormalParametersEnd? optionalFormalParameters =
      formalParameters.getOptionalFormalParameters();
  Set<String> addInitializers = {};
  if (optionalFormalParameters != null) {
    List<FormalParameterEnd> parameters =
        optionalFormalParameters.getFormalParameters();

    for (FormalParameterEnd parameter in parameters) {
      Token token = parameter.getBegin().token;
      if (token.lexeme != "this") {
        continue;
      }
      // Here `this.foo` can't just be replace with `this._foo` as it is
      // (possibly) named and we can't use private stuff in named.
      // Instead we replace it with `dynamic foo` here and add an
      // initializer `this._foo = foo`.
      Token afterDot = token.next!.next!;
      addInitializers.add(afterDot.lexeme);
      replacements[token] = new Replacement(token, token.next!, "dynamic ");
    }
  }

  InitializersEnd? initializers = constructor.getInitializers();

  // First patch up any existing initializers.
  if (initializers != null) {
    List<InitializerEnd> actualInitializers = initializers.getInitializers();
    for (InitializerEnd initializer in actualInitializers) {
      Token token = initializer.getBegin().token;
      // This is only afterDot if there's a dot --- which (probably) is
      // only there if there's a `this`.
      Token afterDot = token.next!.next!;

      // We need to check it's not a redirecting call!
      // TODO(jensj): Handle redirects like this:
      //  class C {
      //    C();
      //    C.redirect() : this();
      //  }
      if (token.lexeme == "this" &&
          namedClassConstructors.contains(afterDot.lexeme)) {
        // Redirect!
        continue;
      }

      if (token.lexeme == "this") {
        // Here `this.foo` can just be replace with `this._foo`.
        assert(namedFields.contains(afterDot.lexeme));
        replacements[afterDot] =
            new Replacement(afterDot, afterDot, "_$afterDot");
      } else if (token.lexeme == "super") {
        // Don't try to patch this one.
      } else if (token.lexeme == "assert") {
        List<IdentifierHandle> identifiers =
            initializer.recursivelyFind<IdentifierHandle>();
        for (Token token in identifiers.map((e) => e.token)) {
          if (namedFields.contains(token.lexeme)) {
            replacements[token] = new Replacement(token, token, "_$token");
          }
        }
      } else {
        assert(namedFields.contains(token.lexeme),
            "${token.lexeme} isn't a known field among ${namedFields}");
        replacements[token] = new Replacement(token, token, "_$token");
      }
    }
  }

  // Then add any new ones.
  if (addInitializers.isNotEmpty && initializers == null) {
    // No initializers => Fake one by inserting `:` and all `_foo = foo`
    // entries.
    Token endToken = formalParameters.endToken;
    String initializerString =
        addInitializers.map((e) => "this._$e = $e").join(",\n");
    replacements[endToken] =
        new Replacement(endToken, endToken, ") : $initializerString");
  } else if (addInitializers.isNotEmpty) {
    // Add to existing initializer list. We add them as the first one(s)
    // so we don't have to insert before the potential super call.
    InitializersBegin firstOne = initializers!.getBegin();
    Token colon = firstOne.token;
    assert(colon.lexeme == ":");
    String initializerString =
        addInitializers.map((e) => "this._$e = $e").join(", ");
    replacements[colon] =
        new Replacement(colon, colon, ": $initializerString,");
  }

  // If there are anything in addInitializers we need to patch
  // up the body too -- if we replace `{this.foo}` with `{dynamic foo}`
  // and the body says `foo = 42;` before that would change the field,
  // now it will change the parameter value. We must patch up all usages
  // - even reads to work on things like
  //  class C {
  //    int field1;
  //    int field2;
  //    C(this.field1) : field2 = field1 + 1;
  //  }
  if (addInitializers.isNotEmpty) {
    BlockFunctionBodyEnd? blockFunctionBody =
        constructor.getBlockFunctionBody();
    if (blockFunctionBody != null) {
      List<IdentifierHandle> identifiers =
          blockFunctionBody.recursivelyFind<IdentifierHandle>();
      for (IdentifierHandle identifier in identifiers) {
        Token token = identifier.token;
        IdentifierContext context = identifier.context;
        if (namedFields.contains(token.lexeme) &&
            addInitializers.contains(token.lexeme)) {
          // For now naively assume that if it's a continuation it says
          // `this.`
          if (!context.isContinuation) {
            replacements[token] = new Replacement(token, token, "_$token");
          }
        }
      }
    }
  }
}

class Replacement {
  final Token beginToken;
  final Token endToken;
  final String replacement;

  Replacement(this.beginToken, this.endToken, this.replacement);
}

String? getExtends(TopLevelDeclarationEnd cls) {
  ClassDeclarationEnd classDeclaration = cls.getClassDeclaration();

  ClassExtendsHandle classExtends = classDeclaration.getClassExtends();
  Token? extendsKeyword = classExtends.extendsKeyword;
  if (extendsKeyword == null) {
    return null;
  } else {
    return extendsKeyword.next.toString();
  }
}

void debugDumpNode(ParserAstNode node) {
  node.children!.forEach((element) {
    print("${element.what} (${element.deprecatedArguments}) "
        "(${element.children})");
  });
}

void debugDumpNodeRecursively(ParserAstNode node, {String indent = ""}) {
  print("$indent${node.what} (${node.deprecatedArguments})");
  if (node.children == null) return;
  node.children!.forEach((element) {
    print("$indent${element.what} (${element.deprecatedArguments})");
    if (element.children != null) {
      element.children!.forEach((element) {
        debugDumpNodeRecursively(element, indent: "  $indent");
      });
    }
  });
}
