// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module fmt

import v.ast
import v.table
import v.token
import strings
import v.util

const (
	tabs    = ['', '\t', '\t\t', '\t\t\t', '\t\t\t\t', '\t\t\t\t\t', '\t\t\t\t\t\t', '\t\t\t\t\t\t\t',
		'\t\t\t\t\t\t\t\t'
	]
	// when to break a line dependant on penalty
	max_len = [0, 35, 85, 93, 100]
)

enum CommentsLevel {
	keep
	indent
}

pub struct Fmt {
pub:
	table             &table.Table
pub mut:
	out_imports       strings.Builder
	out               strings.Builder
	out_save          strings.Builder
	indent            int
	empty_line        bool
	line_len          int
	buffering         bool // expressions will be analyzed later by adjust_complete_line() before finally written
	expr_bufs         []string // and stored here in the meantime (expr_bufs.len-1 = penalties.len = precedences.len)
	penalties         []int // how hard should it be to break line after each expression
	precedences       []int // operator/parenthese precedences for operator at end of each expression
	par_level         int // how many parentheses are put around the current expression
	single_line_if    bool
	cur_mod           string
	file              ast.File
	did_imports       bool
	is_assign         bool
	is_inside_interp  bool
	auto_imports      []string // automatically inserted imports that the user forgot to specify
	import_pos        int // position of the imports in the resulting string for later autoimports insertion
	used_imports      []string // to remove unused imports
	is_debug          bool
	mod2alias         map[string]string // for `import time as t`, will contain: 'time'=>'t'
	use_short_fn_args bool
	it_name           string // the name to replace `it` with
}

pub fn fmt(file ast.File, table &table.Table, is_debug bool) string {
	mut f := Fmt{
		out: strings.new_builder(1000)
		out_imports: strings.new_builder(200)
		table: table
		indent: 0
		file: file
		is_debug: is_debug
	}
	f.process_file_imports(file)
	f.cur_mod = 'main'
	for stmt in file.stmts {
		if stmt is ast.Import {
			// Just remember the position of the imports for now
			f.import_pos = f.out.len
			// f.imports(f.file.imports)
		}
		f.stmt(stmt)
	}
	// for comment in file.comments { println('$comment.line_nr $comment.text')	}
	f.imports(f.file.imports) // now that we have all autoimports, handle them
	res := f.out.str().trim_space() + '\n'
	return res[..f.import_pos] + f.out_imports.str() + res[f.import_pos..] // + '\n'
}

pub fn (mut f Fmt) process_file_imports(file &ast.File) {
	for imp in file.imports {
		f.mod2alias[imp.mod.all_after_last('.')] = imp.alias
	}
}

/*
fn (mut f Fmt) find_comment(line_nr int) {
	for comment in f.file.comments {
		if comment.line_nr == line_nr {
			f.writeln('// FFF $comment.line_nr $comment.text')
			return
		}
	}
}
*/
pub fn (mut f Fmt) write(s string) {
	if !f.buffering {
		if f.indent > 0 && f.empty_line {
			if f.indent < tabs.len {
				f.out.write(tabs[f.indent])
			} else {
				// too many indents, do it the slow way:
				for _ in 0 .. f.indent {
					f.out.write('\t')
				}
			}
			f.line_len += f.indent * 4
		}
		f.out.write(s)
		f.line_len += s.len
		f.empty_line = false
	} else {
		f.out.write(s)
	}
}

pub fn (mut f Fmt) writeln(s string) {
	empty_fifo := f.buffering
	if empty_fifo {
		f.write(s)
		f.expr_bufs << f.out.str()
		f.out = f.out_save
		f.adjust_complete_line()
		f.buffering = false
		for i, p in f.penalties {
			f.write(f.expr_bufs[i])
			f.wrap_long_line(p, true)
		}
		f.write(f.expr_bufs[f.expr_bufs.len - 1])
		f.expr_bufs = []string{}
		f.penalties = []int{}
		f.precedences = []int{}
	}
	if f.indent > 0 && f.empty_line {
		// println(f.indent.str() + s)
		f.out.write(tabs[f.indent])
	}
	f.out.writeln(if empty_fifo {
		''
	} else {
		s
	})
	f.empty_line = true
	f.line_len = 0
}

// adjustments that can only be done after full line is processed. For now
// only prevents line breaks if everything fits in max_len[last] by increasing
// penalties to maximum
fn (mut f Fmt) adjust_complete_line() {
	for i, buf in f.expr_bufs {
		// search for low penalties
		if i == 0 || f.penalties[i - 1] <= 1 {
			precedence := if i == 0 { -1 } else { f.precedences[i - 1] }
			mut len_sub_expr := if i == 0 { buf.len + f.line_len } else { buf.len }
			mut sub_expr_end_idx := f.penalties.len
			// search for next position with low penalty and same precedence to form subexpression
			for j in i .. f.penalties.len {
				if f.penalties[j] <= 1 &&
					f.precedences[j] == precedence && len_sub_expr >= max_len[1] {
					sub_expr_end_idx = j
					break
				} else if f.precedences[j] < precedence {
					// we cannot form a sensible subexpression
					len_sub_expr = C.INT32_MAX
					break
				} else {
					len_sub_expr += f.expr_bufs[j + 1].len
				}
			}
			// if subexpression would fit in single line adjust penalties to actually do so
			if len_sub_expr <= max_len[max_len.len - 1] {
				for j in i .. sub_expr_end_idx {
					f.penalties[j] = max_len.len - 1
				}
				if i > 0 {
					f.penalties[i - 1] = 0
				}
				if sub_expr_end_idx < f.penalties.len {
					f.penalties[sub_expr_end_idx] = 0
				}
			}
		}
		// emergency fallback: decrease penalty in front of long unbreakable parts
		if i > 0 && buf.len > max_len[3] - max_len[1] && f.penalties[i - 1] > 0 {
			f.penalties[i - 1] = if buf.len >= max_len[2] { 0 } else { 1 }
		}
	}
}

pub fn (mut f Fmt) mod(mod ast.Module) {
	f.cur_mod = mod.name
	if mod.is_skipped {
		return
	}
	f.writeln('module $mod.name\n')
}

pub fn (mut f Fmt) imports(imports []ast.Import) {
	if f.did_imports || imports.len == 0 {
		return
	}
	// f.import_pos = f.out.len
	f.did_imports = true
	/*
	if imports.len == 1 {
		imp_stmt_str := f.imp_stmt_str(imports[0])
		f.out_imports.writeln('import ${imp_stmt_str}\n')
	} else if imports.len > 1 {
	*/
	// f.out_imports.writeln('import (')
	for imp in imports {
		if imp.mod !in f.used_imports {
			// TODO bring back once only unused imports are removed
			// continue
		}
		// f.out_imports.write('\t')
		// f.out_imports.writeln(f.imp_stmt_str(imp))
		f.out_imports.write('import ')
		f.out_imports.writeln(f.imp_stmt_str(imp))
	}
	f.out_imports.writeln('')
	// f.out_imports.writeln(')\n')
	// }
}

pub fn (f Fmt) imp_stmt_str(imp ast.Import) string {
	is_diff := imp.alias != imp.mod && !imp.mod.ends_with('.' + imp.alias)
	imp_alias_suffix := if is_diff { ' as $imp.alias' } else { '' }
	return '$imp.mod$imp_alias_suffix'
}

pub fn (mut f Fmt) stmts(stmts []ast.Stmt) {
	f.indent++
	for stmt in stmts {
		f.stmt(stmt)
	}
	f.indent--
}

pub fn (mut f Fmt) stmt(node ast.Stmt) {
	if f.is_debug {
		eprintln('stmt: ${node.position():-42} | node: ${typeof(node):-20}')
	}
	match node {
		ast.AssignStmt {
			for i, left in node.left {
				if left is ast.Ident {
					ident := left as ast.Ident
					var_info := ident.var_info()
					if var_info.is_mut {
						f.write('mut ')
					}
					f.expr(left)
					if i < node.left.len - 1 {
						f.write(', ')
					}
				} else {
					f.expr(left)
				}
			}
			f.is_assign = true
			f.write(' $node.op.str() ')
			for i, val in node.right {
				f.prefix_expr_cast_expr(val)
				if i < node.right.len - 1 {
					f.write(', ')
				}
			}
			if !f.single_line_if {
				f.writeln('')
			}
			f.is_assign = false
		}
		ast.AssertStmt {
			f.write('assert ')
			f.expr(node.expr)
			f.writeln('')
		}
		ast.Attr {
			if node.is_string {
				f.writeln("['$node.name']")
			} else {
				f.writeln('[$node.name]')
			}
		}
		ast.Block {
			f.writeln('{')
			f.stmts(node.stmts)
			f.writeln('}')
		}
		ast.BranchStmt {
			match node.tok.kind {
				.key_break { f.writeln('break') }
				.key_continue { f.writeln('continue') }
				else {}
			}
		}
		ast.Comment {
			f.comment(it)
		}
		ast.CompFor {}
		ast.CompIf {
			inversion := if it.is_not { '!' } else { '' }
			is_opt := if it.is_opt { ' ?' } else { '' }
			f.writeln('\$if $inversion$it.val$is_opt {')
			f.stmts(it.stmts)
			if it.has_else {
				f.writeln('} \$else {')
				f.stmts(it.else_stmts)
			}
			f.writeln('}')
		}
		ast.ConstDecl {
			f.const_decl(it)
		}
		ast.DeferStmt {
			f.writeln('defer {')
			f.stmts(it.stmts)
			f.writeln('}')
		}
		ast.EnumDecl {
			if it.is_pub {
				f.write('pub ')
			}
			name := it.name.after('.')
			f.writeln('enum $name {')
			f.comments(it.comments, false, .indent)
			for field in it.fields {
				f.write('\t$field.name')
				if field.has_expr {
					f.write(' = ')
					f.expr(field.expr)
				}
				f.comments(field.comments, true, .indent)
				f.writeln('')
			}
			f.writeln('}\n')
		}
		ast.ExprStmt {
			f.expr(it.expr)
			if !f.single_line_if {
				f.writeln('')
			}
		}
		ast.FnDecl {
			f.fn_decl(it)
		}
		ast.ForCStmt {
			f.write('for ')
			if it.has_init {
				f.single_line_if = true // to keep all for ;; exprs on the same line
				f.stmt(it.init)
				f.single_line_if = false
			}
			f.write('; ')
			f.expr(it.cond)
			f.write('; ')
			f.stmt(it.inc)
			f.remove_new_line()
			f.writeln(' {')
			f.stmts(it.stmts)
			f.writeln('}')
		}
		ast.ForInStmt {
			f.write('for ')
			if it.key_var != '' {
				f.write(it.key_var)
			}
			if it.val_var != '' {
				if it.key_var != '' {
					f.write(', ')
				}
				f.write(it.val_var)
			}
			f.write(' in ')
			f.expr(it.cond)
			if it.is_range {
				f.write(' .. ')
				f.expr(it.high)
			}
			f.writeln(' {')
			f.stmts(it.stmts)
			f.writeln('}')
		}
		ast.ForStmt {
			f.write('for ')
			f.expr(it.cond)
			if it.is_inf {
				f.writeln('{')
			} else {
				f.writeln(' {')
			}
			f.stmts(it.stmts)
			f.writeln('}')
		}
		ast.GlobalDecl {
			f.write('__global $it.name ')
			f.write(f.type_to_str(it.typ))
			if it.has_expr {
				f.write(' = ')
				f.expr(it.expr)
			}
			f.writeln('')
		}
		ast.GoStmt {
			f.write('go ')
			f.expr(it.call_expr)
			f.writeln('')
		}
		ast.GotoLabel {
			f.writeln('$it.name:')
		}
		ast.GotoStmt {
			f.writeln('goto $it.name')
		}
		ast.HashStmt {
			f.writeln('#$it.val')
		}
		ast.Import {
			// Imports are handled after the file is formatted, to automatically add necessary modules
			// f.imports(f.file.imports)
		}
		ast.InterfaceDecl {
			f.writeln('interface $it.name {')
			for method in it.methods {
				f.write('\t')
				f.writeln(method.stringify(f.table).after('fn '))
			}
			f.writeln('}\n')
		}
		ast.Module {
			f.mod(it)
		}
		ast.Return {
			f.write('return')
			if it.exprs.len > 1 {
				// multiple returns
				f.write(' ')
				for i, expr in it.exprs {
					f.expr(expr)
					if i < it.exprs.len - 1 {
						f.write(', ')
					}
				}
			} else if it.exprs.len == 1 {
				// normal return
				f.write(' ')
				f.expr(it.exprs[0])
			}
			f.writeln('')
		}
		ast.SqlStmt {
			f.write('sql ')
			f.expr(it.db_expr)
			f.writeln(' {')
			match it.kind as k {
				.insert {
					f.writeln('\tinsert $it.object_var_name into ${util.strip_mod_name(it.table_name)}')
				}
				.update {
					f.write('\tupdate ${util.strip_mod_name(it.table_name)} set ')
					for i, col in it.updated_columns {
						f.write('$col = ')
						f.expr(it.update_exprs[i])
						if i < it.updated_columns.len - 1 {
							f.write(', ')
						} else {
							f.write(' ')
						}
					}
					f.write('where ')
					f.expr(it.where_expr)
					f.writeln('')
				}
				.delete {
					// TODO delete
				}
			}
			f.writeln('}')
		}
		ast.StructDecl {
			f.struct_decl(it)
		}
		ast.TypeDecl {
			// already handled in f.imports
			f.type_decl(it)
		}
		ast.UnsafeStmt {
			f.writeln('unsafe {')
			f.stmts(it.stmts)
			f.writeln('}')
		}
	}
}

pub fn (mut f Fmt) type_decl(node ast.TypeDecl) {
	match node {
		ast.AliasTypeDecl {
			if node.is_pub {
				f.write('pub ')
			}
			ptype := f.type_to_str(node.parent_type)
			f.write('type $node.name $ptype')
		}
		ast.FnTypeDecl {
			if node.is_pub {
				f.write('pub ')
			}
			typ_sym := f.table.get_type_symbol(node.typ)
			fn_typ_info := typ_sym.info as table.FnType
			fn_info := fn_typ_info.func
			fn_name := node.name.replace(f.cur_mod + '.', '')
			f.write('type $fn_name = fn (')
			for i, arg in fn_info.args {
				f.write(arg.name)
				mut s := f.table.type_to_str(arg.typ).replace(f.cur_mod + '.', '')
				if arg.is_mut {
					f.write('mut ')
					if s.starts_with('&') {
						s = s[1..]
					}
				}
				is_last_arg := i == fn_info.args.len - 1
				should_add_type := is_last_arg || fn_info.args[i + 1].typ != arg.typ ||
					(fn_info.is_variadic && i == fn_info.args.len - 2)
				if should_add_type {
					if fn_info.is_variadic && is_last_arg {
						f.write(' ...' + s)
					} else {
						f.write(' ' + s)
					}
				}
				if !is_last_arg {
					f.write(', ')
				}
			}
			f.write(')')
			if fn_info.return_type.idx() != table.void_type_idx {
				ret_str := f.table.type_to_str(fn_info.return_type).replace(f.cur_mod + '.',
					'')
				f.write(' ' + ret_str)
			}
		}
		ast.SumTypeDecl {
			if node.is_pub {
				f.write('pub ')
			}
			f.write('type $node.name = ')
			mut sum_type_names := []string{}
			for t in node.sub_types {
				sum_type_names << f.type_to_str(t)
			}
			sum_type_names.sort()
			for i, name in sum_type_names {
				f.write(name)
				if i < sum_type_names.len - 1 {
					f.write(' | ')
				}
				f.wrap_long_line(2, true)
			}
			// f.write(sum_type_names.join(' | '))
		}
	}
	f.writeln('\n')
}

pub fn (mut f Fmt) struct_decl(node ast.StructDecl) {
	if node.is_pub {
		f.write('pub ')
	}
	f.write('struct ')
	f.write_language_prefix(node.language)
	name := node.name.after('.')
	f.writeln('$name {')
	mut max := 0
	for field in node.fields {
		end_pos := field.pos.pos + field.pos.len
		mut comments_len := 0 // Length of comments between field name and type
		for comment in field.comments {
			if comment.pos.pos >= end_pos {
				break
			}
			if comment.pos.pos > field.pos.pos {
				comments_len += '/* $comment.text */ '.len
			}
		}
		if comments_len + field.name.len > max {
			max = comments_len + field.name.len
		}
	}
	for i, field in node.fields {
		if i == node.mut_pos {
			f.writeln('mut:')
		} else if i == node.pub_pos {
			f.writeln('pub:')
		} else if i == node.pub_mut_pos {
			f.writeln('pub mut:')
		}
		end_pos := field.pos.pos + field.pos.len
		comments := field.comments
		if comments.len == 0 {
			f.write('\t$field.name ')
			f.write(strings.repeat(` `, max - field.name.len))
			f.write(f.type_to_str(field.typ))
			if field.attrs.len > 0 {
				f.write(' [' + field.attrs.join(';') + ']')
			}
			if field.has_default_expr {
				f.write(' = ')
				f.prefix_expr_cast_expr(field.default_expr)
			}
			f.write('\n')
			continue
		}
		// Handle comments before field
		mut j := 0
		for j < comments.len && comments[j].pos.pos < field.pos.pos {
			f.indent++
			f.empty_line = true
			f.comment(comments[j])
			f.indent--
			j++
		}
		f.write('\t$field.name ')
		// Handle comments between field name and type
		mut comments_len := 0
		for j < comments.len && comments[j].pos.pos < end_pos {
			comment := '/* ${comments[j].text} */ ' // TODO: handle in a function
			comments_len += comment.len
			f.write(comment)
			j++
		}
		f.write(strings.repeat(` `, max - field.name.len - comments_len))
		f.write(f.type_to_str(field.typ))
		if field.attrs.len > 0 {
			f.write(' [' + field.attrs.join(';') + ']')
		}
		if field.has_default_expr {
			f.write(' = ')
			f.prefix_expr_cast_expr(field.default_expr)
		}
		// Handle comments after field type (same line)
		for j < comments.len && field.pos.line_nr == comments[j].pos.line_nr {
			f.write(' // ${comments[j].text}') // TODO: handle in a function
			j++
		}
		f.write('\n')
	}
	// Handle comments after last field
	for comment in node.end_comments {
		f.indent++
		f.empty_line = true
		f.comment(comment)
		f.indent--
	}
	f.writeln('}\n')
}

pub fn (mut f Fmt) prefix_expr_cast_expr(fexpr ast.Expr) {
	mut is_pe_amp_ce := false
	mut ce := ast.CastExpr{}
	if fexpr is ast.PrefixExpr {
		pe := fexpr as ast.PrefixExpr
		if pe.right is ast.CastExpr && pe.op == .amp {
			ce = pe.right as ast.CastExpr
			ce.typname = f.table.get_type_symbol(ce.typ).name
			is_pe_amp_ce = true
			f.expr(ce)
		}
	}
	if !is_pe_amp_ce {
		f.expr(fexpr)
	}
}

pub fn (f &Fmt) type_to_str(t table.Type) string {
	mut res := f.table.type_to_str(t)
	for res.ends_with('_ptr') {
		// type_ptr => &type
		res = res[0..res.len - 4]
		start_pos := 2 * res.count('[]')
		res = res[0..start_pos] + '&' + res[start_pos..res.len]
	}
	if res.starts_with('[]fixed_') {
		prefix := '[]fixed_'
		res = res[prefix.len..]
		last_underscore_idx := res.last_index('_') or {
			return '[]' + res.replace(f.cur_mod + '.', '')
		}
		limit := res[last_underscore_idx + 1..]
		res = '[' + limit + ']' + res[..last_underscore_idx]
	}
	return res.replace(f.cur_mod + '.', '')
}

pub fn (mut f Fmt) expr(node ast.Expr) {
	if f.is_debug {
		eprintln('expr: ${node.position():-42} | node: ${typeof(node):-20} | $node.str()')
	}
	match node {
		ast.AnonFn {
			f.fn_decl(node.decl)
			if node.is_called {
				f.write('()')
			}
		}
		ast.ArrayInit {
			f.array_init(node)
		}
		ast.AsCast {
			type_str := f.type_to_str(node.typ)
			f.expr(node.expr)
			f.write(' as $type_str')
		}
		ast.Assoc {
			f.writeln('{')
			// f.indent++
			f.writeln('\t$node.var_name |')
			// TODO StructInit copy pasta
			for i, field in node.fields {
				f.write('\t$field: ')
				f.expr(node.exprs[i])
				f.writeln('')
			}
			// f.indent--
			f.write('}')
		}
		ast.BoolLiteral {
			f.write(node.val.str())
		}
		ast.CastExpr {
			node.typname = f.table.get_type_symbol(node.typ).name
			f.write(f.type_to_str(node.typ) + '(')
			f.expr(node.expr)
			f.write(')')
		}
		ast.CallExpr {
			f.call_expr(node)
		}
		ast.CharLiteral {
			f.write('`$node.val`')
		}
		ast.ComptimeCall {
			if node.is_vweb {
				f.write('$' + 'vweb.html()')
			}
		}
		ast.ConcatExpr {
			for i, val in node.vals {
				if i != 0 {
					f.write(' + ')
				}
				f.expr(val)
			}
		}
		ast.EnumVal {
			name := f.short_module(node.enum_name)
			f.write(name + '.' + node.val)
		}
		ast.FloatLiteral {
			f.write(node.val)
		}
		ast.IfExpr {
			f.if_expr(node)
		}
		ast.Ident {
			f.write_language_prefix(node.language)
			if true {
			} else {
			}
			if node.name == 'it' && f.it_name != '' {
				f.write(f.it_name)
			} else if node.kind == .blank_ident {
				f.write('_')
			} else {
				name := f.short_module(node.name)
				// f.write('<$it.name => $name>')
				f.write(name)
				if name.contains('.') {
					f.mark_module_as_used(name)
				}
			}
		}
		ast.IfGuardExpr {
			f.write(node.var_name + ' := ')
			f.expr(node.expr)
		}
		ast.InfixExpr {
			if f.is_inside_interp {
				f.expr(node.left)
				f.write('$node.op.str()')
				f.expr(node.right)
			} else {
				buffering_save := f.buffering
				if !f.buffering {
					f.out_save = f.out
					f.out = strings.new_builder(60)
					f.buffering = true
				}
				f.expr(node.left)
				f.write(' $node.op.str() ')
				f.expr_bufs << f.out.str()
				mut penalty := 3
				if node.left is ast.InfixExpr || node.left is ast.ParExpr {
					penalty--
				}
				if node.right is ast.InfixExpr || node.right is ast.ParExpr {
					penalty--
				}
				f.penalties << penalty
				// combine parentheses level with operator precedence to form effective precedence
				f.precedences << int(token.precedences[node.op]) | (f.par_level << 16)
				f.out = strings.new_builder(60)
				f.buffering = true
				f.expr(node.right)
				if !buffering_save && f.buffering { // now decide if and where to break
					f.expr_bufs << f.out.str()
					f.out = f.out_save
					f.buffering = false
					f.adjust_complete_line()
					for i, p in f.penalties {
						f.write(f.expr_bufs[i])
						f.wrap_long_line(p, true)
					}
					f.write(f.expr_bufs[f.expr_bufs.len - 1])
					f.expr_bufs = []string{}
					f.penalties = []int{}
					f.precedences = []int{}
				}
			}
		}
		ast.IndexExpr {
			f.expr(node.left)
			f.write('[')
			f.expr(node.index)
			f.write(']')
		}
		ast.IntegerLiteral {
			f.write(node.val)
		}
		ast.LockExpr {
			f.lock_expr(node)
		}
		ast.MapInit {
			if node.keys.len == 0 {
				mut ktyp := node.key_type
				mut vtyp := node.value_type
				if vtyp == 0 {
					typ_sym := f.table.get_type_symbol(node.typ)
					minfo := typ_sym.info as table.Map
					ktyp = minfo.key_type
					vtyp = minfo.value_type
				}
				f.write('map[')
				f.write(f.type_to_str(ktyp))
				f.write(']')
				f.write(f.type_to_str(vtyp))
				f.write('{}')
				return
			}
			f.writeln('{')
			f.indent++
			for i, key in node.keys {
				f.expr(key)
				// f.write(strings.repeat(` `, max - field.name.len))
				f.write(': ')
				f.expr(node.vals[i])
				f.writeln('')
			}
			f.indent--
			f.write('}')
		}
		ast.MatchExpr {
			f.match_expr(node)
		}
		ast.None {
			f.write('none')
		}
		ast.OrExpr {
			// shouldn't happen, an or expression
			// is always linked to a call expr
			panic('fmt: OrExpr should to linked to CallExpr')
		}
		ast.ParExpr {
			f.write('(')
			f.par_level++
			f.expr(node.expr)
			f.par_level--
			f.write(')')
		}
		ast.PostfixExpr {
			f.expr(node.expr)
			f.write(node.op.str())
		}
		ast.PrefixExpr {
			f.write(node.op.str())
			f.expr(node.right)
		}
		ast.RangeExpr {
			f.expr(node.low)
			f.write('..')
			f.expr(node.high)
		}
		ast.SelectorExpr {
			f.expr(node.expr)
			f.write('.')
			f.write(node.field_name)
		}
		ast.SizeOf {
			if node.is_type {
				f.write('sizeof(')
				if node.type_name != '' {
					f.write(f.short_module(node.type_name))
				} else {
					f.write(f.type_to_str(node.typ))
				}
				f.write(')')
			} else {
				f.write('sizeof(')
				f.expr(node.expr)
				f.write(')')
			}
		}
		ast.SqlExpr {
			// sql app.db { select from Contributor where repo == id && user == 0 }
			f.write('sql ')
			f.expr(node.db_expr)
			f.writeln(' {')
			f.write('\t')
			f.write('select ')
			esym := f.table.get_type_symbol(node.table_type)
			node.table_name = esym.name
			if node.is_count {
				f.write('count ')
			} else {
				if node.fields.len > 0 {
					for tfi, tf in node.fields {
						f.write(tf.name)
						if tfi < node.fields.len - 1 {
							f.write(', ')
						}
					}
					f.write(' ')
				}
			}
			f.write('from ${util.strip_mod_name(node.table_name)}')
			f.write(' ')
			if node.has_where {
				f.write('where ')
				f.expr(node.where_expr)
				f.write(' ')
			}
			if node.has_limit {
				f.write('limit ')
				f.expr(node.limit_expr)
				f.write(' ')
			}
			if node.has_offset {
				f.write('offset ')
				f.expr(node.offset_expr)
			}
			f.writeln('')
			f.write('}')
		}
		ast.StringLiteral {
			if node.is_raw {
				f.write('r')
			}
			if node.val.contains("'") && !node.val.contains('"') {
				f.write('"$node.val"')
			} else {
				f.write("'$node.val'")
			}
		}
		ast.StringInterLiteral {
			// TODO: this code is very similar to ast.Expr.str()
			mut contains_single_quote := false
			for val in node.vals {
				if val.contains("'") {
					contains_single_quote = true
				}
				if val.contains('"') {
					contains_single_quote = false
					break
				}
			}
			if contains_single_quote {
				f.write('"')
			} else {
				f.write("'")
			}
			f.is_inside_interp = true
			for i, val in node.vals {
				f.write(val)
				if i >= node.exprs.len {
					break
				}
				f.write('$')
				fspec_str, needs_braces := node.get_fspec_braces(i)
				if needs_braces {
					f.write('{')
					f.expr(node.exprs[i])
					f.write(fspec_str)
					f.write('}')
				} else {
					f.expr(node.exprs[i])
				}
			}
			f.is_inside_interp = false
			if contains_single_quote {
				f.write('"')
			} else {
				f.write("'")
			}
		}
		ast.StructInit {
			f.struct_init(node)
		}
		ast.Type {
			f.write(f.type_to_str(node.typ))
		}
		ast.TypeOf {
			f.write('typeof(')
			f.expr(node.expr)
			f.write(')')
		}
		ast.Likely {
			if node.is_likely {
				f.write('_likely_')
			} else {
				f.write('_unlikely_')
			}
			f.write('(')
			f.expr(node.expr)
			f.write(')')
		}
	}
}

pub fn (mut f Fmt) wrap_long_line(penalty int, add_indent bool) bool {
	if f.line_len <= max_len[penalty] {
		return false
	}
	if f.out.buf[f.out.buf.len - 1] == ` ` {
		f.out.go_back(1)
	}
	f.write('\n' + tabs[f.indent + if add_indent {
		1
	} else {
		0
	}])
	f.line_len = 0
	return true
}

pub fn (mut f Fmt) call_args(args []ast.CallArg) {
	for i, arg in args {
		if arg.is_mut {
			f.write('mut ')
		}
		if i > 0 {
			f.wrap_long_line(2, true)
		}
		f.expr(arg.expr)
		if i < args.len - 1 {
			if f.is_inside_interp {
				f.write(',')
			} else {
				f.write(', ')
			}
		}
	}
}

pub fn (mut f Fmt) or_expr(or_block ast.OrExpr) {
	match or_block.kind {
		.absent {}
		.block {
			if or_block.stmts.len == 0 {
				f.write(' or { }')
			} else {
				f.writeln(' or {')
				f.stmts(or_block.stmts)
				f.write('}')
			}
		}
		.propagate {
			f.write('?')
		}
	}
}

pub fn (mut f Fmt) comment(node ast.Comment) {
	if !node.text.contains('\n') {
		is_separate_line := node.text.starts_with('|')
		mut s := if is_separate_line { node.text[1..] } else { node.text }
		if s == '' {
			s = '//'
		} else {
			s = '// ' + s
		}
		if !is_separate_line && f.indent > 0 {
			f.remove_new_line() // delete the generated \n
			f.write(' ')
		}
		f.writeln(s)
		return
	}
	lines := node.text.split_into_lines()
	f.writeln('/*')
	for line in lines {
		f.writeln(line)
		f.empty_line = false
	}
	f.empty_line = true
	f.writeln('*/')
}

pub fn (mut f Fmt) comments(some_comments []ast.Comment, remove_last_new_line bool, level CommentsLevel) {
	for c in some_comments {
		if !f.out.last_n(1)[0].is_space() {
			f.write('\t')
		}
		if level == .indent {
			f.indent++
		}
		f.comment(c)
		if level == .indent {
			f.indent--
		}
	}
	if remove_last_new_line {
		f.remove_new_line()
	}
}

pub fn (mut f Fmt) fn_decl(node ast.FnDecl) {
	// println('$it.name find_comment($it.pos.line_nr)')
	// f.find_comment(it.pos.line_nr)
	s := node.stringify(f.table)
	f.write(s.replace(f.cur_mod + '.', '')) // `Expr` instead of `ast.Expr` in mod ast
	if node.language == .v {
		f.writeln(' {')
		f.stmts(node.stmts)
		f.write('}')
		if !node.is_anon {
			f.writeln('\n')
		}
	} else {
		f.writeln('\n')
	}
	// Mark all function's used type so that they are not removed from imports
	for arg in node.args {
		f.mark_types_module_as_used(arg.typ)
	}
	f.mark_types_module_as_used(node.return_type)
}

// foo.bar.fn() => bar.fn()
pub fn (mut f Fmt) short_module(name string) string {
	if !name.contains('.') {
		return name
	}
	vals := name.split('.')
	if vals.len < 2 {
		return name
	}
	mname := vals[vals.len - 2]
	symname := vals[vals.len - 1]
	aname := f.mod2alias[mname]
	if aname == '' {
		return symname
	}
	return '${aname}.$symname'
}

pub fn (mut f Fmt) lock_expr(lex ast.LockExpr) {
	f.write('lock ')
	for i, v in lex.lockeds {
		if i > 0 {
			f.write(', ')
		}
		f.expr(v)
	}
	f.write(' {')
	f.writeln('')
	f.stmts(lex.stmts)
	f.write('}')
}

pub fn (mut f Fmt) if_expr(it ast.IfExpr) {
	single_line := it.branches.len == 2 && it.has_else &&
		it.branches[0].stmts.len == 1 && it.branches[1].stmts.len == 1 &&
		(it.is_expr || f.is_assign)
	f.single_line_if = single_line
	for i, branch in it.branches {
		if branch.comments.len > 0 {
			f.comments(branch.comments, true, .keep)
		}
		if i == 0 {
			f.write('if ')
			f.expr(branch.cond)
			f.write(' {')
		} else if i < it.branches.len - 1 || !it.has_else {
			f.write('} else if ')
			f.expr(branch.cond)
			f.write(' {')
		} else if i == it.branches.len - 1 && it.has_else {
			f.write('} else {')
		}
		if single_line {
			f.write(' ')
		} else {
			f.writeln('')
		}
		f.stmts(branch.stmts)
		if single_line {
			f.write(' ')
		}
	}
	f.write('}')
	f.single_line_if = false
}

pub fn (mut f Fmt) call_expr(node ast.CallExpr) {
	/*
	if node.args.len == 1 && node.expected_arg_types.len == 1 && node.args[0].expr is ast.StructInit &&
		node.args[0].typ == node.expected_arg_types[0] {
		// struct_init := node.args[0].expr as ast.StructInit
		// if struct_init.typ == node.args[0].typ {
		f.use_short_fn_args = true
		// }
	}
	*/
	if node.is_method {
		/*
		// x.foo!() experiment
		mut is_mut := false
		if node.left is ast.Ident {
			scope := f.file.scope.innermost(node.pos.pos)
			x := node.left as ast.Ident
			var := scope.find_var(x.name) or {
				panic(err)
			}
			println(var.typ)
			if var.typ != 0 {
				sym := f.table.get_type_symbol(var.typ)
				if method := f.table.type_find_method(sym, node.name) {
					is_mut = method.args[0].is_mut
				}
			}
		}
		*/
		if node.left is ast.Ident {
			it := node.left as ast.Ident
			// `time.now()` without `time imported` is processed as a method call with `time` being
			// a `node.left` expression. Import `time` automatically.
			// TODO fetch all available modules
			if it.name in ['time', 'os', 'strings', 'math', 'json', 'base64'] {
				if it.name !in f.auto_imports {
					f.auto_imports << it.name
					f.file.imports << ast.Import{
						mod: it.name
						alias: it.name
					}
				}
				// for imp in f.file.imports {
				// println(imp.mod)
				// }
			}
		}
		f.expr(node.left)
		f.write('.' + node.name + '(')
		f.call_args(node.args)
		f.write(')')
		// if is_mut {
		// f.write('!')
		// }
		f.or_expr(node.or_block)
	} else {
		f.write_language_prefix(node.language)
		name := f.short_module(node.name)
		f.mark_module_as_used(name)
		f.write('$name')
		if node.generic_type != 0 && node.generic_type != table.void_type {
			f.write('<')
			f.write(f.type_to_str(node.generic_type))
			f.write('>')
		}
		f.write('(')
		f.call_args(node.args)
		f.write(')')
		f.or_expr(node.or_block)
	}
	f.use_short_fn_args = false
}

pub fn (mut f Fmt) match_expr(it ast.MatchExpr) {
	f.write('match ')
	if it.is_mut {
		f.write('mut ')
	}
	f.expr(it.cond)
	if it.cond is ast.Ident {
		ident := it.cond as ast.Ident
		f.it_name = ident.name
	} else if it.cond is ast.SelectorExpr {
		// `x.y as z`
		// if ident.name != it.var_name && it.var_name != '' {
	}
	if it.var_name != '' && f.it_name != it.var_name {
		f.write(' as $it.var_name')
	}
	f.writeln(' {')
	f.indent++
	mut single_line := true
	for branch in it.branches {
		if branch.stmts.len > 1 {
			single_line = false
			break
		}
		if branch.stmts.len == 0 {
			continue
		}
		stmt := branch.stmts[0]
		if stmt is ast.ExprStmt {
			// If expressions inside match branches can't be one a single line
			expr_stmt := stmt as ast.ExprStmt
			if !expr_is_single_line(expr_stmt.expr) {
				single_line = false
				break
			}
		} else if stmt is ast.Comment {
			single_line = false
			break
		}
	}
	for branch in it.branches {
		if branch.comment.text != '' {
			f.comment(branch.comment)
		}
		if !branch.is_else {
			// normal branch
			for j, expr in branch.exprs {
				f.expr(expr)
				if j < branch.exprs.len - 1 {
					f.write(', ')
				}
			}
		} else {
			// else branch
			f.write('else')
		}
		if branch.stmts.len == 0 {
			f.writeln(' {}')
		} else {
			if single_line {
				f.write(' { ')
			} else {
				f.writeln(' {')
			}
			f.stmts(branch.stmts)
			if single_line {
				f.remove_new_line()
				f.writeln(' }')
			} else {
				f.writeln('}')
			}
		}
		if branch.post_comments.len > 0 {
			f.comments(branch.post_comments, false, .keep)
		}
	}
	f.indent--
	f.write('}')
	f.it_name = ''
}

pub fn (mut f Fmt) remove_new_line() {
	mut i := 0
	for i = f.out.len - 1; i >= 0; i-- {
		if !f.out.buf[i].is_space() { // != `\n` {
			break
		}
	}
	f.out.go_back(f.out.len - i - 1)
	f.empty_line = false
	// f.writeln('sdf')
}

pub fn (mut f Fmt) mark_types_module_as_used(typ table.Type) {
	sym := f.table.get_type_symbol(typ)
	f.mark_module_as_used(sym.name)
}

// `name` is a function (`foo.bar()`) or type (`foo.Bar{}`)
pub fn (mut f Fmt) mark_module_as_used(name string) {
	if !name.contains('.') {
		return
	}
	pos := name.last_index('.') or {
		0
	}
	mod := name[..pos]
	if mod in f.used_imports {
		return
	}
	f.used_imports << mod
	// println('marking module $mod as used')
}

fn (mut f Fmt) write_language_prefix(lang table.Language) {
	match lang {
		.c { f.write('C.') }
		.js { f.write('JS.') }
		else {}
	}
}

fn expr_is_single_line(expr ast.Expr) bool {
	match expr {
		ast.IfExpr { return false }
		else {}
	}
	return true
}

pub fn (mut f Fmt) array_init(it ast.ArrayInit) {
	if it.exprs.len == 0 && it.typ != 0 && it.typ != table.void_type {
		// `x := []string`
		typ_sym := f.table.get_type_symbol(it.typ)
		if typ_sym.kind == .array && typ_sym.name.starts_with('array_map') {
			ainfo := typ_sym.info as table.Array
			map_typ_sym := f.table.get_type_symbol(ainfo.elem_type)
			minfo := map_typ_sym.info as table.Map
			mk := f.table.get_type_symbol(minfo.key_type).name
			mv := f.table.get_type_symbol(minfo.value_type).name
			for _ in 0 .. ainfo.nr_dims {
				f.write('[]')
			}
			f.write('map[$mk]$mv')
			f.write('{')
			if it.has_len {
				f.write('len: ')
				f.expr(it.len_expr)
			}
			if it.has_cap {
				f.write('cap: ')
				f.expr(it.cap_expr)
			}
			if it.has_default {
				f.write('init: ')
				f.expr(it.default_expr)
			}
			f.write('}')
			return
		}
		f.write(f.type_to_str(it.typ))
		f.write('{')
		// TODO copypasta
		if it.has_len {
			f.write('len: ')
			f.expr(it.len_expr)
			if it.has_cap || it.has_default {
				f.write(', ')
			}
		}
		if it.has_cap {
			f.write('cap: ')
			f.expr(it.cap_expr)
			if it.has_default {
				f.write(', ')
			}
		}
		if it.has_default {
			f.write('init: ')
			f.expr(it.default_expr)
		}
		f.write('}')
		return
	}
	// `[1,2,3]`
	// type_sym := f.table.get_type_symbol(it.typ)
	f.write('[')
	mut inc_indent := false
	mut last_line_nr := it.pos.line_nr // to have the same newlines between array elements
	for i, expr in it.exprs {
		mut penalty := 3
		line_nr := expr.position().line_nr
		if last_line_nr < line_nr {
			penalty--
		}
		if i == 0 ||
			it.exprs[i - 1] is ast.ArrayInit ||
			it.exprs[i - 1] is ast.StructInit ||
			it.exprs[i - 1] is ast.MapInit || it.exprs[i - 1] is ast.CallExpr {
			penalty--
		}
		if expr is ast.ArrayInit ||
			expr is ast.StructInit || expr is ast.MapInit ||
			expr is ast.CallExpr {
			penalty--
		}
		is_new_line := f.wrap_long_line(penalty, !inc_indent)
		if is_new_line && !inc_indent {
			f.indent++
			inc_indent = true
		}
		if !is_new_line && i > 0 {
			f.write(' ')
		}
		f.expr(expr)
		if i == it.exprs.len - 1 {
			if is_new_line {
				f.writeln('')
			}
		} else {
			f.write(',')
		}
		last_line_nr = line_nr
	}
	if inc_indent {
		f.indent--
	}
	f.write(']')
	// `[100]byte`
	if it.is_fixed {
		f.write(f.type_to_str(it.elem_type))
	}
}

pub fn (mut f Fmt) struct_init(it ast.StructInit) {
	type_sym := f.table.get_type_symbol(it.typ)
	// f.write('<old name: $type_sym.name>')
	mut name := type_sym.name
	if !name.starts_with('C.') {
		name = f.short_module(type_sym.name).replace(f.cur_mod + '.', '') // TODO f.type_to_str?
	}
	if name == 'void' {
		name = ''
	}
	if it.fields.len == 0 {
		// `Foo{}` on one line if there are no fields
		f.write('$name{}')
	} else if it.is_short {
		// `Foo{1,2,3}` (short syntax )
		// if name != '' {
		f.write('$name{')
		// }
		for i, field in it.fields {
			f.prefix_expr_cast_expr(field.expr)
			if i < it.fields.len - 1 {
				f.write(', ')
			}
		}
		f.write('}')
	} else {
		if f.use_short_fn_args {
			f.writeln('')
		} else {
			f.writeln('$name{')
		}
		f.indent++
		for field in it.fields {
			f.write('$field.name: ')
			f.prefix_expr_cast_expr(field.expr)
			f.writeln('')
		}
		f.indent--
		if !f.use_short_fn_args {
			f.write('}')
		}
	}
}

pub fn (mut f Fmt) const_decl(it ast.ConstDecl) {
	if it.is_pub {
		f.write('pub ')
	}
	f.writeln('const (')
	mut max := 0
	for field in it.fields {
		if field.name.len > max {
			max = field.name.len
		}
	}
	f.indent++
	for field in it.fields {
		comments := field.comments
		mut j := 0
		for j < comments.len && comments[j].pos.pos < field.pos.pos {
			f.comment(comments[j])
			j++
		}
		name := field.name.after('.')
		f.write('$name ')
		f.write(strings.repeat(` `, max - field.name.len))
		f.write('= ')
		f.expr(field.expr)
		f.writeln('')
	}
	f.indent--
	f.writeln(')\n')
}
