" R3 W-D drain-bound survey driver (sourced with +source by
" r3_drain_survey.py). NVIM_SURVEY_MODE selects the candidate workload;
" every mode times its own body and writes wall seconds to $NVIM_AB_RESULT.
" Candidates are nvim-hosted only (nvim is the only OOB-patched client).
set nomore noswapfile nowritebackup number
let s:mode = get(environ(), 'NVIM_SURVEY_MODE', 'scroll_nosyn')
let s:t0 = []

function! s:finish(extra) abort
  let elapsed = reltimefloat(reltime(s:t0))
  call writefile([json_encode(extend({'seconds': elapsed, 'mode': s:mode,
        \ 'oob_env': getenv('KITTY_TUI_OOB_FD') isnot v:null}, a:extra))],
        \ $NVIM_AB_RESULT)
  quitall!
endfunction

function! s:scroll_nosyn(timer) abort
  syntax off
  let s:t0 = reltime()
  let pages = 0
  for l in range(3)
    normal! gg
    while line('w$') < line('$')
      execute "normal! \<C-f>"
      redraw
      let pages += 1
    endwhile
  endfor
  call s:finish({'pages': pages})
endfunction

function! s:subst(timer) abort
  syntax on
  let s:t0 = reltime()
  for i in range(30)
    silent! execute '%s/\va(bcdefghijklmnop)/A\1/g'
    redraw!
    silent! execute '%s/\vA(bcdefghijklmnop)/a\1/g'
    redraw!
  endfor
  call s:finish({})
endfunction

function! s:paste(timer) abort
  syntax off
  let s:t0 = reltime()
  normal! ggVGy
  for i in range(8)
    normal! Gp
    redraw!
  endfor
  call s:finish({'lines': line('$')})
endfunction

function! s:on_term_close() abort
  call s:finish({})
endfunction

function! s:term(cmd) abort
  let s:t0 = reltime()
  augroup R3Survey
    autocmd!
    autocmd TermClose * call s:on_term_close()
  augroup END
  enew!
  execute 'terminal' a:cmd
  normal! G
endfunction

function! s:dispatch(timer) abort
  if s:mode ==# 'term_cat'
    call s:term('cat ' . $NVIM_SURVEY_FILE)
  elseif s:mode ==# 'term_flood'
    call s:term('python3.14 ' . $NVIM_SURVEY_GEN)
  elseif s:mode ==# 'subst'
    call s:subst(0)
  elseif s:mode ==# 'paste'
    call s:paste(0)
  else
    call s:scroll_nosyn(0)
  endif
endfunction

autocmd VimEnter * call timer_start(500, function('s:dispatch'))
