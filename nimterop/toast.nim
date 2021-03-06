import os, osproc, strformat, strutils, times

import "."/treesitter/[api, c, cpp]

import "."/[ast, compat, globals, getters, grammar]

proc printLisp(gState: State, root: TSNode) =
  var
    node = root
    nextnode: TSNode
    depth = 0

  while true:
    if not node.tsNodeIsNull() and depth > -1:
      if gState.pretty:
        stdout.write spaces(depth)
      let
        (line, col) = gState.getLineCol(node)
      stdout.write &"({$node.tsNodeType()} {line} {col} {node.tsNodeEndByte() - node.tsNodeStartByte()}"
    else:
      break

    if node.tsNodeNamedChildCount() != 0:
      if gState.pretty:
        gecho ""
      nextnode = node.tsNodeNamedChild(0)
      depth += 1
    else:
      if gState.pretty:
        gecho ")"
      else:
        stdout.write ")"
      nextnode = node.tsNodeNextNamedSibling()

    if nextnode.tsNodeIsNull():
      while true:
        node = node.tsNodeParent()
        depth -= 1
        if depth == -1:
          break
        if gState.pretty:
          gecho spaces(depth) & ")"
        else:
          stdout.write ")"
        if node == root:
          break
        if not node.tsNodeNextNamedSibling().tsNodeIsNull():
          node = node.tsNodeNextNamedSibling()
          break
    else:
      node = nextnode

    if node == root:
      break

proc process(gState: State, path: string, astTable: AstTable) =
  doAssert existsFile(path), &"Invalid path {path}"

  var
    parser = tsParserNew()
    ext = path.splitFile().ext

  defer:
    parser.tsParserDelete()

  if gState.mode.Bl:
    if ext in [".h", ".c"]:
      gState.mode = "c"
    elif ext in [".hxx", ".hpp", ".hh", ".H", ".h++", ".cpp", ".cxx", ".cc", ".C", ".c++"]:
      gState.mode = "cpp"

  if gState.preprocess:
    gState.code = gState.getPreprocessor(path)
  else:
    gState.code = readFile(path)

  doAssert gState.code.nBl, "Empty file or preprocessor error"

  if gState.mode == "c":
    doAssert parser.tsParserSetLanguage(treeSitterC()), "Failed to load C parser"
  elif gState.mode == "cpp":
    doAssert parser.tsParserSetLanguage(treeSitterCpp()), "Failed to load C++ parser"
  else:
    doAssert false, &"Invalid parser {gState.mode}"

  var
    tree = parser.tsParserParseString(nil, gState.code.cstring, gState.code.len.uint32)
    root = tree.tsTreeRootNode()

  defer:
    tree.tsTreeDelete()

  if gState.past:
    gState.printLisp(root)
  elif gState.pnim:
    gState.printNim(path, root, astTable)
  elif gState.preprocess:
    gecho gState.code

# CLI processing with default values
proc main(
    check = false,
    debug = false,
    defines: seq[string] = @[],
    dynlib: string = "",
    includeDirs: seq[string] = @[],
    mode = modeDefault,
    nim: string = "nim",
    nocomments = false,
    output = "",
    past = false,
    pgrammar = false,
    pluginSourcePath: string = "",
    pnim = false,
    prefix: seq[string] = @[],
    preprocess = false,
    recurse = false,
    stub = false,
    suffix: seq[string] = @[],
    symOverride: seq[string] = @[],
    source: seq[string]
  ) =

  # Setup global state with arguments
  var gState = State(
    debug: debug,
    defines: defines,
    dynlib: dynlib,
    includeDirs: includeDirs,
    mode: mode,
    nim: nim,
    nocomments: nocomments,
    past: past,
    pluginSourcePath: pluginSourcePath,
    pnim: pnim,
    prefix: prefix,
    preprocess: preprocess,
    pretty: true,
    recurse: recurse,
    suffix: suffix,
    symOverride: symOverride
  )

  # Split some arguments with ,
  gState.symOverride = gState.symOverride.getSplitComma()
  gState.prefix = gState.prefix.getSplitComma()
  gState.suffix = gState.suffix.getSplitComma()

  if pluginSourcePath.nBl:
    gState.loadPlugin(pluginSourcePath)

  var
    outputFile = output
    check = check or stub

  # Fix output file extention for Nim mode
  if outputFile.len != 0 and pnim:
    if outputFile.splitFile().ext != ".nim":
      outputFile = outputFile & ".nim"

  # Check needs a file
  if check and outputFile.len == 0:
    outputFile = getTempDir() / "toast_" & ($getTime().toUnix()).addFileExt("nim")

  # Redirect output to file
  if outputFile.len != 0:
    doAssert gState.outputHandle.open(outputFile, fmWrite),
      &"Failed to write to {outputFile}"

  # Process grammar into AST
  let
    astTable = parseGrammar()

  if pgrammar:
    # Print AST of grammar
    gState.printGrammar(astTable)
  elif source.nBl:
    # Print source after preprocess or Nim output
    if gState.pnim:
      gState.printNimHeader()
    for src in source:
      gState.process(src.expandSymlinkAbs(), astTable)

  # Close outputFile
  if outputFile.len != 0:
    gState.outputHandle.close()

  # Check Nim output
  if gState.pnim and check:
    # Run nim check on generated wrapper
    var
      (check, err) = execCmdEx(&"{gState.nim} check {outputFile}")
    if err != 0:
      # Failed check so try stubbing
      if stub:
        # Find undeclared identifiers in error
        var
          data = ""
          stubData = ""
        for line in check.splitLines:
          if "undeclared identifier" in line:
            try:
              # Add stub of object type
              stubData &= "  " & line.split("'")[1] & " = object\n"
            except:
              discard

        # Include in wrapper file
        data = outputFile.readFile()
        let
          idx = data.find("\ntype\n")
        if idx != -1:
          # In first existing type block
          data = data[0 ..< idx+6] & stubData & data[idx+6 .. ^1]
        else:
          # At the top if none already
          data = "type\n" & stubData & data
        outputFile.writeFile(data)

        # Rerun nim check on stubbed wrapper
        (check, err) = execCmdEx(&"{gState.nim} check {outputFile}")
        doAssert err == 0, data & "# Nim check with stub failed:\n\n" & check
      else:
        doAssert err == 0, outputFile.readFile() & "# Nim check failed:\n\n" & check

  # Print wrapper if temporarily redirected to file
  if check and output.len == 0:
    stdout.write outputFile.readFile()

when isMainModule:
  # Setup cligen command line help and short flags
  import cligen
  dispatch(main, help = {
    "check": "check generated wrapper with compiler",
    "debug": "enable debug output",
    "defines": "definitions to pass to preprocessor",
    "dynlib": "Import symbols from library in specified Nim string",
    "includeDirs": "include directory to pass to preprocessor",
    "mode": "language parser: c or cpp",
    "nim": "use a particular Nim executable (default: $PATH/nim)",
    "nocomments": "exclude top-level comments from output",
    "output": "file to output content - default stdout",
    "past": "print AST output",
    "pgrammar": "print grammar",
    "pluginSourcePath": "Nim file to build and load as a plugin",
    "pnim": "print Nim output",
    "preprocess": "run preprocessor on header",
    "recurse": "process #include files",
    "source" : "C/C++ source/header",
    "prefix": "Strip prefix from identifiers",
    "stub": "stub out undefined type references as objects",
    "suffix": "Strip suffix from identifiers",
    "symOverride": "skip generating specified symbols"
  }, short = {
    "check": 'k',
    "debug": 'd',
    "defines": 'D',
    "dynlib": 'l',
    "includeDirs": 'I',
    "nocomments": 'c',
    "output": 'o',
    "past": 'a',
    "pgrammar": 'g',
    "pnim": 'n',
    "prefix": 'E',
    "preprocess": 'p',
    "recurse": 'r',
    "stub": 's',
    "suffix": 'F',
    "symOverride": 'O'
  })
