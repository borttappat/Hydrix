# Vim - User Configuration
#
# Full vim configuration - installs vim, sets it as default editor,
# and deploys .vimrc via home.activation (writable between rebuilds).

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;

  vimrc = pkgs.writeText "vimrc" ''
    " Restrict to the 16 terminal palette colors so every highlight comes from wal.
    " With t_Co=256, names like LightBlue resolve to fixed xterm-cube indices (81)
    " that wal never sets.
    set notermguicolors
    set t_Co=16

    function! s:WalHi()
      highlight Search ctermbg=3 ctermfg=0
      highlight IncSearch ctermbg=6 ctermfg=0
      highlight Visual ctermbg=8 ctermfg=NONE
      highlight LineNr ctermfg=8
      highlight CursorLineNr ctermfg=7
    endfunction
    autocmd ColorScheme * call s:WalHi()

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
    call s:WalHi()

    autocmd BufEnter * execute "chdir ".escape(expand("%:p:h"), "")
    autocmd BufWritePost *Xresources,*Xdefaults !xrdb %
  '';
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    environment.systemPackages = [ pkgs.vim ];

    home-manager.users.${username} = { lib, ... }: {
      home.activation.vimConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        [ -L "$HOME/.vimrc" ] && rm -f "$HOME/.vimrc"
        cat ${vimrc} > "$HOME/.vimrc"
      '';
    };
  };
}
