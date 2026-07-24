" R3 A/B scroll-replay driver (sourced with +source by r3_nvim_ab.py).
" Waits for VimEnter + a settle timer so a real editor mode has been
" entered (the OOB channel arms on the first real mode-change), then
" page-scrolls through the whole fixture with forced redraws and writes
" the wall time to $NVIM_AB_RESULT.
set nomore noswapfile nowritebackup number
syntax on

function! R3Replay(timer) abort
  let t0 = reltime()
  let pages = 0
  normal! gg
  while line('w$') < line('$')
    execute "normal! \<C-f>"
    redraw
    let pages += 1
  endwhile
  let elapsed = reltimefloat(reltime(t0))
  call writefile([json_encode({'seconds': elapsed, 'pages': pages,
        \ 'lines': line('$'), 'oob_env': getenv('KITTY_TUI_OOB_FD') isnot v:null})],
        \ $NVIM_AB_RESULT)
  quitall!
endfunction

autocmd VimEnter * call timer_start(500, function('R3Replay'))
