" Force vim to use 16 terminal colors instead of 24-bit RGB
" This ensures colors match the Stylix terminal palette (shown by fastfetch)
" Overrides Stylix's 'set termguicolors'
set notermguicolors

" Use cterm colors (0-15) which map to terminal palette
" These override Stylix's colorscheme highlights
autocmd ColorScheme * highlight Search ctermbg=3 ctermfg=0
autocmd ColorScheme * highlight IncSearch ctermbg=6 ctermfg=0
autocmd ColorScheme * highlight Visual ctermbg=8 ctermfg=NONE
autocmd ColorScheme * highlight LineNr ctermfg=8
autocmd ColorScheme * highlight CursorLineNr ctermfg=7

set background=dark
set number relativenumber
set ignorecase
set smartcase
set tabstop=4
set shiftwidth=4
set softtabstop=4
set expandtab
set hlsearch
set incsearch

autocmd BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g`\"" | endif

set noswapfile
set clipboard=unnamed
set scrolloff=10
set showcmd
set history=1000

set wildmenu
set wildmode=list:longest
set wildignore=*.docx,*.jpg,*.png,*.gif,*.pdf,*.pyc,*.exe,*.flv,*.img,*.xlsx

set statusline=
set statusline+=\ %F\ %M\ %Y\ %R
set statusline+=%=
set statusline+=\ ascii:\ %b\ hex:\ 0x%B\ row:\ %l\ col:\ %c\ percent:\ %p%%
set laststatus=2

set autoindent
set nobackup
set copyindent
set smarttab
set fileformat=unix
set ruler

syntax on

autocmd BufEnter * execute "chdir ".escape(expand("%:p:h"), "")
autocmd BufWritePost *Xresources,*Xdefaults !xrdb %