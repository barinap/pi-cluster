set nocompatible " must be the first line
set backspace=2
filetype on
filetype indent on
filetype plugin on
syntax on
set laststatus=2
set statusline=%<%f\%h%m%r%=%-20.(line=%l\ \ col=%c%V\ \ totlin=%L%)\ \ \%h%m%r%=%-40(bytval=0x%B,%n%Y%)\%P
set ofu=syntaxcomplete#Complete
set number
map <F12> :NERDTree<CR>
map <F11> :Explore<CR>
noremap ěě @
noremap ššš #
noremap čč $
noremap řř %
noremap žž ^
noremap ýý &
noremap áá *
noremap íí (
noremap éé )
noremap úú {
noremap ůů ;
inoremap ěě @
inoremap ššš #
inoremap čč $
inoremap řř %
inoremap žž ^
inoremap ýý &
inoremap áá *
inoremap íí (
inoremap éé )
inoremap úú {
inoremap ůů ;
inoremap §§ “
