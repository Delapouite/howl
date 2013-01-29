import Scintilla, styler, BufferLines, Chunk, config, signal from howl
import File from howl.fs
import style from howl.ui
import PropertyObject from howl.aux.moon
import destructor from howl.aux

background_sci = Scintilla!
background_buffer = setmetatable {}, __mode: 'v'
buffer_titles = setmetatable {}, __mode: 'v'
title_counters = {}

file_title = (file) ->
  title = file.basename
  while buffer_titles[title]
    file = file.parent
    return title if not file
    title = file.basename .. File.separator .. title

  title

title_counter = (title) ->
  title_counters[title] = 1 if not title_counters[title]
  title_counters[title] += 1
  title_counters[title]

class Context extends PropertyObject
  new: (@buffer, @pos) => super!

  @property word: get: =>
    return @_word if @_word
    sci = @buffer.sci
    b_pos = @buffer\byte_offset @pos
    start_pos = sci\word_start_position b_pos - 1, true
    end_pos = sci\word_end_position b_pos - 1, true
    start_pos, end_pos = @buffer\char_offset start_pos + 1, end_pos + 1
    @_word = Chunk @buffer, start_pos, end_pos - 1
    @_word

  @property line: get: =>
    @_line or= @buffer.lines\at_pos @pos
    @_line

  @property word_prefix: get: => @word.text\sub 1, @pos - @word.start_pos
  @property word_suffix: get: => @word.text\sub (@pos - @word.start_pos) + 1
  @property prefix: get: => @line\sub 1, (@pos - @line.start_pos)
  @property suffix: get: => @line\sub (@pos - @line.start_pos) + 1
  @meta {
    __eq: (a, b) ->
      t = typeof a
      t == 'Context' and t == typeof(b) and a.buffer == b.buffer and a.pos == b.pos
  }

class Buffer extends PropertyObject
  new: (mode = {}, sci) =>
    super!

    if sci
      @_sci = sci
      @doc = sci\get_doc_pointer!
      @scis = { sci }
    else
      @doc = background_sci\create_document!
      @destructor = destructor background_sci\release_document, @doc
      @scis = {}

    @config = config.local_proxy!
    @completers = {}
    @mode = mode
    @properties = {}
    @multibyte_from = nil
    @_len = nil
    @sci_listener =
      on_text_inserted: self\_on_text_inserted
      on_text_deleted: self\_on_text_deleted

  @property file:
    get: => @_file
    set: (file) =>
      @_file = file
      @title = file_title file
      @text = file.exists and file.contents or ''
      @dirty = false
      @can_undo = false

  @property mode:
    get: => @_mode
    set: (mode = {}) =>
      @_mode = mode
      @config.chain_to mode.config

  @property title:
    get: => @_title or 'Untitled'
    set: (title) =>
      title ..= '<' .. title_counter(title) .. '>' if buffer_titles[title]
      @_title = title
      buffer_titles[title] = self

  @property text:
    get: => @sci\get_text!
    set: (text) =>
      text = u text
      @sci\clear_all!
      @sci\add_text text.size, text
      @sci\set_code_page Scintilla.SC_CP_UTF8
      @multibyte_from = text.multibyte and 0 or nil

  @property dirty:
    get: => @sci\get_modify!
    set: (status) =>
      if not status then @sci\set_save_point!
      else -- there's no specific message for marking as dirty
        @append ' '
        @delete @size, 1

  @property can_undo:
    get: => @sci\can_undo!
    set: (value) => @sci\empty_undo_buffer! if not value

  @property size: get: => @sci\get_text_length!
  @property length: get: =>
    @_len or= @sci\count_characters 0, @size
    @multibyte_from = nil if @_len == @size
    @_len

  @property lines: get: => BufferLines self, @sci

  @property eol:
    get: =>
      switch @sci\get_eolmode!
        when Scintilla.SC_EOL_LF then '\n'
        when Scintilla.SC_EOL_CRLF then '\r\n'
        when Scintilla.SC_EOL_CR then '\r'
    set: (eol) =>
      s_mode = switch eol
        when '\n' then Scintilla.SC_EOL_LF
        when '\r\n' then Scintilla.SC_EOL_CRLF
        when '\r' then Scintilla.SC_EOL_CR
        else error 'Unknown eol mode'
      @sci\set_eolmode s_mode

  @property showing: get: => #@scis > 0

  @property last_shown:
    get: => #@scis > 0 and os.time! or @_last_shown
    set: (timestamp) => @_last_shown = timestamp

  @property destroyed: get: => @doc == nil

  @property multibyte: get: => @multibyte_from != nil

  destroy: =>
    return if @destroyed
    error 'Cannot destroy a currently showing buffer', 2 if @showing

    if @destructor
      @destructor.defuse!
      @sci\release_document @doc
      @destructor = nil

    @doc = nil

  chunk: (pos, length) => Chunk self, pos, pos + length - 1

  context_at: (pos) => Context self, pos

  delete: (pos, length) =>
    start_pos, end_pos = @byte_offset pos, pos + length
    @sci\delete_range start_pos - 1, end_pos - start_pos

  insert: (text, pos) =>
    text = u text
    b_pos = @byte_offset pos
    @sci\insert_text b_pos - 1, text
    pos + #text

  append: (text) => @sci\append_text #text, text

  replace: (pattern, replacement) =>
    matches = {}
    pos = 1
    text = @text

    while pos < @length
      start_pos, end_pos, match = text\find pattern, pos
      break unless start_pos

      -- only replace the match within pattern if present
      end_pos = match and (start_pos + #match - 1) or end_pos

      append matches, start_pos
      append matches, end_pos
      pos = end_pos + 1

    return if #matches == 0
    b_offsets = @byte_offset matches

    for i = #b_offsets, 1, -2
      start_pos = b_offsets[i - 1]
      end_pos = b_offsets[i]

      with @sci
        \set_target_start start_pos - 1
        \set_target_end end_pos
        \replace_target -1, replacement

    #matches / 2

  save: =>
    if @file
      if @config.strip_trailing_whitespace
        ws = '[\t ]'
        @replace "(#{ws}+)#{@eol}", ''
        @replace "(#{ws}+)$", ''

      @file.contents = @text
      @dirty = false
      signal.emit 'buffer-saved', buffer: self

  as_one_undo: (f) =>
    @sci\begin_undo_action!
    status, ret = pcall f
    @sci\end_undo_action!
    error ret if not status

  undo: => @sci\undo!
  redo: => @sci\redo!
  char_offset: (...) => @_offset u.char_offset, ...
  byte_offset: (...) => @_offset u.byte_offset, ...

  @property sci:
    get: =>
      error 'Attempt to invoke operation on destroyed buffer', 2 if @destroyed
      if @_sci then return @_sci

      if background_buffer[1] != self
        background_sci\set_doc_pointer self.doc
        background_buffer[1] = self
        background_sci.listener = @sci_listener

      background_sci

  add_sci_ref: (sci) =>
    append @scis, sci
    @_sci = sci
    if background_buffer[1] == self
      background_sci.listener = nil

  remove_sci_ref: (sci) =>
    @scis = [s for s in *@scis when s != sci]
    @_sci = @scis[1] if sci == @_sci
    @_last_shown = os.time! if #@scis == 0

  lex: (end_pos) =>
    if @_mode and @_mode.lexer
      styler.style_text @sci, self, end_pos, @_mode.lexer
    else
      styler.mark_as_styled @sci, self

  _on_text_inserted: (args) =>
    if args.text.multibyte
      @multibyte_from = @multibyte_from and math.min(@multibyte_from, args.at_pos) or args.at_pos

    @_len = nil
    signal.emit 'buffer-modified', buffer: self

  _on_text_deleted: (args) =>
    if @multibyte and args.at_pos < @multibyte_from
      @multibyte_from = args.at_pos

    @_len = nil
    signal.emit 'buffer-modified', buffer: self

  _offset: (f, ...) =>
    args = {...}
    is_table = type(args[1]) == 'table'
    arg_offsets = is_table and args[1] or args
    local offsets

    if @multibyte and arg_offsets[#arg_offsets] >= @multibyte_from
      offsets = f @sci\raw!, arg_offsets
      for i = #offsets,1,-1
        res = offsets[i]
        arg = arg_offsets[i]
        if res == arg
          @multibyte_from = res
          break
    else
      offsets = {}
      size = @size
      for offset in *arg_offsets
        if offset < 1 or offset > size + 1
          error "Offset '#{offset}' out of bounds (size = #{size})", 2
        append offsets, offset

    return offsets if is_table
    return table.unpack offsets

  @meta {
    __len: => @length
    __tostring: => @title
  }

-- Config variables

with config
  .define
    name: 'strip_trailing_whitespace'
    description: 'Whether trailing whitespace will be removed upon save'
    default: true
    type_of: 'boolean'

-- Signals

signal.register 'buffer-saved',
  description: 'Signaled right after a buffer was saved',
  parameters:
    buffer: 'The buffer that was saved'

signal.register 'buffer-modified',
  description: 'Signaled right after a buffer was modified',
  parameters:
    buffer: 'The buffer that was modified'

return Buffer
