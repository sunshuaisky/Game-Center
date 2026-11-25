const games = [
  {title:'Hollow Knight',platform:'macOS',type:'mac',art:'hollowknight',subtitle:'HOLLOW KNIGHT',favorite:false,added:13},
  {title:'Super Mario Advance 4',platform:'GBA',type:'gba',art:'mario',subtitle:'SUPER MARIO',favorite:true,added:12},
  {title:'The Legend of Zelda',platform:'GBA',type:'gba',art:'zelda',subtitle:'THE MINISH CAP',added:11},
  {title:'Metroid Fusion',platform:'GBA',type:'gba',art:'metroid',subtitle:'METROID',added:10},
  {title:'Stardew Valley',platform:'macOS',type:'mac',art:'stardew',subtitle:'STARDEW VALLEY',favorite:true,added:9},
  {title:'Celeste',platform:'macOS',type:'mac',art:'celeste',subtitle:'CELESTE',added:8},
  {title:'Animal Crossing',platform:'NDS',type:'nds',art:'animal',subtitle:'WILD WORLD',added:7},
  {title:'Pokémon Emerald',platform:'GBA',type:'gba',art:'pokemon',subtitle:'POKÉMON',favorite:true,added:6},
  {title:'Castlevania',platform:'NDS',type:'nds',art:'castlevania',subtitle:'DAWN OF SORROW',added:5},
  {title:'Hades',platform:'macOS',type:'mac',art:'hades',subtitle:'HADES',added:4},
  {title:'Inside',platform:'macOS',type:'mac',art:'inside',subtitle:'INSIDE',added:3},
  {title:'Hollow Knight: Silksong',platform:'macOS',type:'mac',art:'silksong',subtitle:'SILKSONG',added:2},
  {title:'Minecraft',platform:'NDS',type:'nds',art:'minecraft',subtitle:'MINECRAFT',added:1}
];
const labels = {all:'全部游戏',recent:'最近游玩',favorites:'收藏',gba:'Game Boy Advance',nds:'Nintendo DS',mac:'macOS'};
let activeFilter='all', searchTerm='', gridView=false, toastTimer;
const appearanceToggle=document.querySelector('#appearanceToggle');
const savedTheme=localStorage.getItem('game-center-theme');
let theme=savedTheme||(window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
function applyTheme(){document.documentElement.dataset.theme=theme;document.querySelector('meta[name=theme-color]').content=theme==='dark'?'#151515':'#fafafa';appearanceToggle.setAttribute('aria-pressed',String(theme==='dark'));appearanceToggle.setAttribute('aria-label',theme==='dark'?'切换浅色模式':'切换暗黑模式');appearanceToggle.title=theme==='dark'?'切换浅色模式':'切换暗黑模式';appearanceToggle.firstElementChild.textContent=theme==='dark'?'☼':'◐'}
applyTheme();
const systemAppearance=window.matchMedia('(prefers-color-scheme: dark)');
systemAppearance.addEventListener('change',event=>{if(!localStorage.getItem('game-center-theme')){theme=event.matches?'dark':'light';applyTheme()}});
appearanceToggle.addEventListener('click',()=>{theme=theme==='dark'?'light':'dark';localStorage.setItem('game-center-theme',theme);applyTheme()});
const grid=document.querySelector('#gameGrid'), empty=document.querySelector('#emptyState'), toast=document.querySelector('#toast');
function showToast(message){toast.textContent=message;toast.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>toast.classList.remove('show'),2600)}
function visibleGames(){let result=games.filter(g=>activeFilter==='all'||(activeFilter==='recent'?g.added>=8:activeFilter==='favorites'?g.favorite:g.type===activeFilter));if(searchTerm)result=result.filter(g=>g.title.toLowerCase().includes(searchTerm.toLowerCase())||g.platform.toLowerCase().includes(searchTerm.toLowerCase()));return result}
function render(){const result=visibleGames();document.querySelector('#allCount').textContent=games.length;document.querySelectorAll('.platform-group .count').forEach((node,index)=>{node.textContent=games.filter(g=>g.type===['gba','nds','mac'][index]).length});grid.innerHTML='';grid.classList.toggle('list-view',gridView);document.querySelector('#currentSection').textContent=labels[activeFilter];document.querySelector('#listHeading').textContent=activeFilter==='all'?'所有游戏':labels[activeFilter];document.querySelector('#resultCount').textContent=`${result.length} 款游戏`;empty.hidden=result.length!==0;grid.hidden=result.length===0;for(const game of result){const card=document.createElement('article');card.className='game-card';card.tabIndex=0;card.innerHTML=`<div class="cover art-${game.art}"><span class="cover-label">${game.platform}</span><span class="cover-title">${game.title}<small class="cover-subtitle">${game.subtitle}</small></span><button class="card-favorite ${game.favorite?'is-favorite':''}" aria-label="${game.favorite?'取消收藏':'加入收藏'}">${game.favorite?'♥':'♡'}</button></div><div class="game-meta"><span class="game-title">${game.title}</span></div><div class="game-platform">${game.platform}</div>`;card.addEventListener('click',e=>{if(e.target.closest('.card-favorite')){e.stopPropagation();game.favorite=!game.favorite;render();return}openDetails(game)});card.addEventListener('keydown',e=>{if(e.key==='Enter')openDetails(game)});grid.append(card)}}
function openDetails(game){document.querySelector('#detailTitle').textContent=game.title;document.querySelector('#detailDialog').showModal()}
document.querySelectorAll('.nav-item').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('.nav-item').forEach(x=>x.classList.remove('active'));button.classList.add('active');activeFilter=button.dataset.filter;render()}));
document.querySelector('#searchInput').addEventListener('input',e=>{searchTerm=e.target.value;render()});
document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='f'){e.preventDefault();document.querySelector('#searchInput').focus()}if(e.key==='Escape')document.querySelector('#detailDialog').close()});
document.querySelector('#viewToggle').addEventListener('click',()=>{gridView=!gridView;document.querySelector('#viewToggle').classList.toggle('selected',gridView);showToast(gridView?'已切换为列表视图':'已切换为网格视图')});
document.querySelector('#sortButton').addEventListener('click',()=>showToast('当前按最近添加排序'));
document.querySelector('#clearSearch').addEventListener('click',()=>{searchTerm='';document.querySelector('#searchInput').value='';render()});
document.querySelector('#importButton').addEventListener('click',()=>document.querySelector('#fileInput').click());
document.querySelector('#addGameButton').addEventListener('click',()=>document.querySelector('#fileInput').click());
document.querySelector('#fileInput').addEventListener('change',e=>{const files=[...e.target.files];if(files.length)showToast(`已选择 ${files.length} 个文件，原型暂不写入游戏库`);e.target.value=''});
document.querySelector('#playFeatured').addEventListener('click',()=>showToast('启动器接口将在后续版本接入'));
document.querySelector('#dialogPlay').addEventListener('click',()=>showToast('启动器接口将在后续版本接入'));
const featuredGame=games.find(game=>game.title==='Hollow Knight');
document.querySelector('#featureDetails').addEventListener('click',()=>openDetails(featuredGame));
document.querySelector('#closeDialog').addEventListener('click',()=>document.querySelector('#detailDialog').close());
document.querySelector('#manageLibrary').addEventListener('click',()=>showToast('游戏资料夹设置将在后续版本提供'));
document.querySelector('.feature-favorite').addEventListener('click',e=>{featuredGame.favorite=!featuredGame.favorite;e.currentTarget.classList.toggle('is-favorite',featuredGame.favorite);e.currentTarget.textContent=featuredGame.favorite?'♥':'♡';showToast(featuredGame.favorite?'已加入收藏':'已取消收藏');if(activeFilter==='favorites')render()});
render();
