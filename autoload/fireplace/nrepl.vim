" Location:     autoload/nrepl/fireplace.vim

if exists("g:autoloaded_fireplace_nrepl")
  finish
endif
let g:autoloaded_fireplace_nrepl = 1

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '.*\zs<SNR>\d\+_'),''))
endfunction

function! fireplace#nrepl#next_id() abort
  return fireplace#transport#id()
endfunction

if !exists('g:fireplace_nrepl_sessions')
  let g:fireplace_nrepl_sessions = {}
endif

augroup fireplace_nrepl_connection
  autocmd!
  autocmd VimLeave * for s:session in values(g:fireplace_nrepl_sessions)
        \ |   if s:session.transport.alive()
        \ |     call s:session.close()
        \ |   endif
        \ | endfor
augroup END

function! fireplace#nrepl#for(transport) abort
  let client = copy(s:nrepl)
  let client.transport = a:transport
  if a:transport.has_op('classpath')
    let response = a:transport.message({'op': 'classpath'})[0]
    if type(get(response, 'classpath')) == type([])
      let client._path = response.classpath
    endif
  endif
  if !has_key(client, '_path')
    let response = client.process({'op': 'eval', 'code':
          \ '[(System/getProperty "path.separator") (or (System/getProperty "fake.class.path") (System/getProperty "java.class.path") "")]', 'session': ''})
    let client._path = split(eval(response.value[-1][5:-2]), response.value[-1][2])
  endif
  let client.session = client.process({'op': 'clone', 'session': ''})['new-session']
  let g:fireplace_nrepl_sessions[client.session] = client
  return client
endfunction

function! s:nrepl_close() dict abort
  if has_key(self, 'session')
    try
      unlet! g:fireplace_nrepl_sessions[self.session]
      call self.message({'op': 'close'}, '')
    catch
    finally
      unlet self.session
    endtry
  endif
  return self
endfunction

function! s:nrepl_clone() dict abort
  let client = copy(self)
  if has_key(self, 'session')
    let client.session = client.process({'op': 'clone'})['new-session']
    let g:fireplace_nrepl_sessions[client.session] = client
  endif
  return client
endfunction

function! s:nrepl_path() dict abort
  return self._path
endfunction

function! fireplace#nrepl#combine(responses) abort
  return fireplace#transport#combine(a:responses)
endfunction

function! s:nrepl_process(msg) dict abort
  let combined = self.message(a:msg, v:t_dict)
  if index(combined.status, 'error') < 0
    return combined
  endif
  let status = filter(copy(combined.status), 'v:val !=# "done" && v:val !=# "error"')
  throw 'nREPL: ' . tr(join(status, ', '), '-', ' ')
endfunction

function! s:nrepl_eval(expr, ...) dict abort
  let msg = {"op": "eval"}
  let msg.code = a:expr
  let options = a:0 ? a:1 : {}

  for [k, v] in items(options)
    let msg[tr(k, '_', '-')] = v
  endfor

  if !has_key(msg, 'ns') && has_key(self, 'ns')
    let msg.ns = self.ns
  endif

  if !has_key(msg, 'id')
    let msg.id = fireplace#transport#id()
  endif

  try
    let response = self.process(msg)
  finally
    if !exists('response')
      let session = get(msg, 'session', self.session)
      if !empty(session)
        call self.message({'op': 'interrupt', 'session': session, 'interrupt-id': msg.id}, '')
      endif
      throw 'Clojure: Interrupt'
    endif
  endtry
  if has_key(response, 'ns') && empty(get(options, 'ns'))
    let self.ns = response.ns
  endif

  if has_key(response, 'ex') && !empty(get(msg, 'session', 1))
    let response.stacktrace = s:extract_last_stacktrace(self, get(msg, 'session', self.session))
  endif

  if has_key(response, 'value')
    let response.value = response.value[-1]
  endif

  return response
endfunction

function! s:process_stacktrace_entry(entry) abort
  if !has_key(a:entry, 'class')
    return ''
  endif
  let str = a:entry.class.'.'.a:entry.method
  if !empty(get(a:entry, 'file'))
    let str .= '('.a:entry.file.':'.a:entry.line.')'
  endif
  return str
endfunction

function! s:extract_last_stacktrace(nrepl, session) abort
  if a:nrepl.has_op('stacktrace')
    let stacktrace = a:nrepl.message({'op': 'stacktrace', 'session': a:session})
    if len(stacktrace) > 0 && has_key(stacktrace[0], 'stacktrace')
      let stacktrace = stacktrace[0].stacktrace
    endif

    call map(stacktrace, 's:process_stacktrace_entry(v:val)')
    call filter(stacktrace, '!empty(v:val)')
    if !empty(stacktrace)
      return stacktrace
    endif
  endif
  let format_st =
        \ '(let [st (or (when (= "#''cljs.core/str" (str #''str))' .
        \               ' (.-stack *e))' .
        \             ' (.getStackTrace *e))]' .
        \  ' (symbol' .
        \    ' (str "\n\b"' .
        \         ' (if (string? st)' .
        \           ' st' .
        \           ' (let [parts (if (= "class [Ljava.lang.StackTraceElement;" (str (type st)))' .
        \                         ' (map str st)' .
        \                         ' (seq (amap st idx ret (str (aget st idx)))))]' .
        \             ' (apply str (interleave (repeat "\n") parts))))' .
        \         ' "\n\b\n")))'
  let response = a:nrepl.process({'op': 'eval', 'code': '['.format_st.' *3 *2 *1]', 'ns': 'user', 'session': a:session})
  try
    let stacktrace = split(get(split(response.value[0], "\n\b\n"), 1, ""), "\n")
  catch
    throw string(response)
  endtry
  call a:nrepl.message({'op': 'eval', 'code': '(*1 1)', 'ns': 'user', 'session': a:session})
  call a:nrepl.message({'op': 'eval', 'code': '(*2 2)', 'ns': 'user', 'session': a:session})
  call a:nrepl.message({'op': 'eval', 'code': '(*3 3)', 'ns': 'user', 'session': a:session})
  return stacktrace
endfunction

let s:keepalive = tempname()
call writefile([getpid()], s:keepalive)

function! s:nrepl_prepare(msg) dict abort
  let msg = copy(a:msg)
  if !has_key(msg, 'id')
    let msg.id = fireplace#transport#id()
  endif
  if empty(get(msg, 'ns', 1))
    unlet msg.ns
  endif
  if empty(get(msg, 'session', 1))
    unlet msg.session
  elseif !has_key(msg, 'session')
    let msg.session = self.session
  endif
  return msg
endfunction

function! s:nrepl_message(msg, ...) dict abort
  let msg = self.prepare(a:msg)
  return call(self.transport.message, [msg] + a:000, self.transport)
endfunction

function! s:nrepl_has_op(op) dict abort
  return self.transport.has_op(a:op)
endfunction

let s:nrepl = {
      \ 'close': s:function('s:nrepl_close'),
      \ 'clone': s:function('s:nrepl_clone'),
      \ 'prepare': s:function('s:nrepl_prepare'),
      \ 'message': s:function('s:nrepl_message'),
      \ 'eval': s:function('s:nrepl_eval'),
      \ 'has_op': s:function('s:nrepl_has_op'),
      \ 'path': s:function('s:nrepl_path'),
      \ 'process': s:function('s:nrepl_process')}
