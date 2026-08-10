# drawio-check.ps1 -- controle de LOGIQUE et de COHERENCE sur le MODELE .drawio.
#
# Pourquoi ce fichier existe. Il verifie ce que le dessin DECLARE, pas ce a quoi
# il ressemble -- et c'est la toute la division du travail. Une arete dont le
# bout est pose pile sur une boite mais qui n'a pas de `target` a l'air juste et
# ne l'est pas : on s'en apercoit en deplacant la boite. Un enfant dont la
# geometrie contredit le parent declare a l'air normal. Une legende qui imprime
# quatre regles de couleur est une affirmation que l'oeil n'audite pas. Le modele
# porte tout cela explicitement : on le lit la ou c'est ecrit.
#
# CE QUE CET OUTIL NE PEUT PAS VOIR, et il faut le savoir :
#   - le TRACE des connecteurs. draw.io le calcule au rendu ; le modele ne garde
#     que les points d'inflexion. "Ce trait coupe-t-il cette boite" n'est plus
#     verifie par machine : la figure se dessine dans draw.io, sur une toile que
#     quelqu'un regarde, et l'oeil attrape cela en quelques secondes. C'etait le
#     role de diagram-check.js, retire le 2026-08-10 -- ecrit pour une epoque ou
#     la figure etait du SVG a la main et ou personne ne la voyait en l'editant.
#     Un controle qui double l'oeil ne rapporte rien et reste a maintenir.
#   - la largeur RENDUE d'un texte. Le modele a la largeur de la boite et la
#     chaine, pas la police. L'estimation ci-dessous est declaree comme telle.
#   - si la figure est VRAIE. Aucun script ne repond a cela.
#
# Discipline du projet : une regle qui n'a jamais echoue ne compte pas. Chaque
# regle porte une mutation temoin ; si la mutation ne la fait pas echouer, le
# script REFUSE de rendre un verdict.
#
# ASCII pur.

# Par defaut : la figure publiee a cote de ce script, resolue relativement au
# script lui-meme et non au repertoire courant. Aucun chemin absolu ici : ce
# fichier est publie.
param(
  [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'sheets\linuxcnc-system-overview.drawio'),
  [switch]$Verbeux
)

# Garde-fou ajoute le 2026-08-10, apres avoir vu le script mentir sur sa propre
# panne. Sans fichier, Build() rendait un modele vide, les sept mutations temoins
# ne changeaient rien, et le script annoncait "REFUSE : une regle ne sait pas
# echouer" en listant ses sept regles comme cassees. Il refusait -- donc il etait
# sur -- mais pour la mauvaise raison, et le message envoyait chercher un defaut
# dans les regles au lieu d'un chemin.
# A noter, parce que c'est la cause : le $Path par defaut se resout depuis le
# PARENT DU SCRIPT, ce qui ne vaut que depuis l'emplacement publie
# (publish/linuxcnc-audit/tools/ -> ../sheets/). Lance depuis drawio-work/, il
# visait un sheets/ inexistant a la racine du dossier de travail.
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
  Write-Output "ERREUR : modele introuvable -- $Path"
  Write-Output ''
  Write-Output 'Ce script ne devine pas ou est le modele. Le chemin par defaut vise'
  Write-Output '..\sheets\linuxcnc-system-overview.drawio RELATIVEMENT AU SCRIPT, ce qui'
  Write-Output 'ne fonctionne que depuis publish\linuxcnc-audit\tools\. Depuis ailleurs :'
  Write-Output '  powershell -File <script> -Path drawio-work\linuxcnc-system-overview.drawio'
  exit 2
}

# SECOND PREALABLE, ajoute le 2026-08-10 : le XML doit etre EN CLAIR.
# Par defaut draw.io compresse le contenu (base64 + deflate). Le modele n'est
# alors qu'un bloc opaque : Build() rend un modele VIDE, et un modele vide passe
# TOUTES les regles -- une boite qui n'existe pas ne viole rien. Le script
# refuserait quand meme, ses mutations temoins ne changeant rien sur du vide,
# mais il annoncerait "une regle ne sait pas echouer" et enverrait chercher un
# defaut dans les regles au lieu d'une case a decocher. Meme forme d'erreur que
# le chemin manquant, meme reponse : nommer la cause, pas le symptome.
function EstCompresse([string]$texte) { $texte -notmatch '<mxGraphModel' }

$texte = [IO.File]::ReadAllText($Path)
if (EstCompresse $texte) {
  Write-Output "ERREUR : le modele est COMPRESSE -- $Path"
  Write-Output ''
  Write-Output 'Aucune regle ne peut etre appliquee : le contenu est un bloc base64 opaque,'
  Write-Output 'illisible en revue, indiffable, et inaccessible a un agent qui edite du texte.'
  Write-Output 'Dans draw.io : File > Properties > Compressed a DECOCHER, puis reenregistrer.'
  Write-Output 'A verifier apres le premier enregistrement humain, pas seulement a la creation.'
  exit 2
}

# ---------- modele -----------------------------------------------------------
function Build([string]$xmlText) {
  [xml]$doc = $xmlText
  $cells = @($doc.mxfile.diagram.mxGraphModel.root.mxCell)
  $byId = @{}
  foreach ($c in $cells) { if ($c.id) { $byId[[string]$c.id] = $c } }

  $vertices = @(); $edges = @(); $rules = @()
  foreach ($c in $cells) {
    $id = [string]$c.id
    if ($id -eq '0' -or $id -eq '1') { continue }
    $st = [string]$c.style
    if ($c.vertex -eq '1') {
      $g = $c.mxGeometry
      if (-not $g -or -not $g.width) { continue }
      # geometrie absolue : les enfants sont relatifs a leur parent
      $x = [double]$g.x; $y = [double]$g.y; $p = [string]$c.parent; $n = 0
      while ($byId.ContainsKey($p) -and $byId[$p].mxGeometry -and $byId[$p].mxGeometry.width -and $n -lt 8) {
        $x += [double]$byId[$p].mxGeometry.x; $y += [double]$byId[$p].mxGeometry.y
        $p = [string]$byId[$p].parent; $n++
      }
      $vertices += [pscustomobject]@{
        id=$id; parent=[string]$c.parent; style=$st; value=[string]$c.value
        x=$x; y=$y; w=[double]$g.width; h=[double]$g.height
        lx=[double]$g.x; ly=[double]$g.y
        text  = ($st -like 'text;*')
        fill  = (Tok $st 'fillColor')
        container = ($st -match 'container=1')
        detached  = ($st -match 'detached=1')
      }
    }
    elseif ($c.edge -eq '1') {
      $src = [string]$c.source; $dst = [string]$c.target
      if (($st -match 'endArrow=none') -and -not $src -and -not $dst) {
        $pts = @($c.mxGeometry.mxPoint)
        $sp = $pts | Where-Object { $_.as -eq 'sourcePoint' }
        $tp = $pts | Where-Object { $_.as -eq 'targetPoint' }
        if ($sp -and $tp) {
          $rules += [pscustomobject]@{ id=$id; style=$st; x1=[double]$sp.x; y1=[double]$sp.y; x2=[double]$tp.x; y2=[double]$tp.y }
          continue
        }
      }
      $edges += [pscustomobject]@{ id=$id; src=$src; dst=$dst; value=[string]$c.value; style=$st }
    }
  }
  $deg = @{}
  foreach ($e in $edges) { foreach ($k in @($e.src, $e.dst)) { if ($k) { $deg[$k] = [int]$deg[$k] + 1 } } }
  $vById = @{}; foreach ($v in $vertices) { $vById[$v.id] = $v }
  return [pscustomobject]@{ vertices=$vertices; edges=$edges; rules=$rules; deg=$deg; vById=$vById }
}
function Tok([string]$style, [string]$key) {
  if ($style -match ([regex]::Escape($key) + '=([^;]*)')) { return $Matches[1] }
  return $null
}
function Boxes($m) { @($m.vertices | Where-Object { -not $_.text }) }
function Lbl($v) {
  $t = ((([string]$v.value) -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
  $t = $t -replace '&#183;', '.' -replace '&#8212;', '-' -replace '&#9312;', '(1)'
  if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
  if (-not $t) { $t = '(sans libelle)' }
  return $t
}
function Inside($a, $b, $tol = 1) {   # $a entierement dans $b ?
  ($a.x -ge $b.x - $tol) -and ($a.y -ge $b.y - $tol) -and
  (($a.x + $a.w) -le ($b.x + $b.w + $tol)) -and (($a.y + $a.h) -le ($b.y + $b.h + $tol))
}
function SegCrossesBox($r, $b) {      # frontiere horizontale contre une boite
  $ymin = [Math]::Min($r.y1, $r.y2); $ymax = [Math]::Max($r.y1, $r.y2)
  $xmin = [Math]::Min($r.x1, $r.x2); $xmax = [Math]::Max($r.x1, $r.x2)
  ($ymax -gt $b.y) -and ($ymin -lt ($b.y + $b.h)) -and ($xmax -gt $b.x) -and ($xmin -lt ($b.x + $b.w))
}

# ---------- regles -----------------------------------------------------------
# Chacune rend une liste de chaines. Liste vide = la regle passe.

function R1_AretesPendantes($m) {
  $f = @()
  foreach ($e in $m.edges) {
    if (-not $e.src -or -not $e.dst) {
      $f += "arete $($e.id) sans " + $(if (-not $e.src) { 'source' } else { 'cible' }) + " : elle est ancree a un point, elle ne suivra pas les boites"
    } elseif (-not $m.vById.ContainsKey($e.src) -or -not $m.vById.ContainsKey($e.dst)) {
      $f += "arete $($e.id) pointe une cellule inexistante"
    }
  }
  $f
}

function R2_BoitesOrphelines($m) {
  $f = @()
  foreach ($b in (Boxes $m)) {
    if ($b.parent -ne '1') { continue }          # un enfant est porte par son parent
    if ($b.container -or $b.detached) { continue }
    if ([int]$m.deg[$b.id] -eq 0) {
      $f += "boite $($b.id) '$(Lbl $b)' n'a aucun lien et ne declare pas detached=1"
    }
  }
  $f
}

function R3_ParentContredit($m) {
  $f = @()
  foreach ($v in $m.vertices) {
    if (-not $m.vById.ContainsKey($v.parent)) { continue }
    $p = $m.vById[$v.parent]
    if (-not (Inside $v $p 2)) {
      $f += "cellule $($v.id) '$(Lbl $v)' declare $($p.id) pour parent mais sort de sa geometrie"
    }
  }
  $f
}

function R4_Couleurs($m) {
  $f = @()
  $vert = '#d5e8d4'; $gris = '#eee'; $orange = '#ffe6cc'; $blanc = '#fffdf5'
  $rtapi = @(Boxes $m | Where-Object { (Lbl $_) -like 'rtapi_app*' })
  $ligneDistant = ($m.rules | Sort-Object y1 | Select-Object -First 1)
  $ligneMachine = ($m.rules | Sort-Object y1 | Select-Object -Last 1)
  # Les pastilles de la legende PORTENT une couleur pour l'expliquer ; elles
  # n'affirment rien sur la machine. Exemption geometrique et non par nom : une
  # boite situee DANS le panneau de legende est un echantillon, pas un sujet.
  $legende = @(Boxes $m | Where-Object { (Lbl $_) -like 'LEGEND*' }) | Select-Object -First 1
  $seuilBlanc = SeuilBlanc $m
  if ($seuilBlanc -lt 0) { $f += "regle couleur 4 : la phrase 'every WHITE box must carry at least N link' est introuvable dans la legende ; la regle n'a pas ete appliquee" }

  foreach ($b in (Boxes $m)) {
    if ($legende -and $b.id -ne $legende.id -and (Inside $b $legende 2)) { continue }
    if ($b.fill -eq $vert -and $rtapi.Count -eq 1) {
      if (-not (Inside $b $rtapi[0] 2)) { $f += "regle couleur 1 : la boite VERTE $($b.id) '$(Lbl $b)' n'est pas dans rtapi_app" }
    }
    if ($b.fill -eq $gris -and $ligneDistant) {
      if (($b.y + $b.h) -gt $ligneDistant.y1) { $f += "regle couleur 2 : la boite GRISE $($b.id) '$(Lbl $b)' n'est pas au-dessus de la ligne du distant" }
    }
    if ($b.fill -eq $orange -and $ligneMachine) {
      if ($b.y -lt $ligneMachine.y1) { $f += "regle couleur 3 : la boite ORANGE $($b.id) '$(Lbl $b)' n'est pas sous la ligne de la machine" }
    }
    if ($b.fill -eq $blanc -and $seuilBlanc -ge 0) {
      if ([int]$m.deg[$b.id] -lt $seuilBlanc) { $f += "regle couleur 4 : la boite BLANCHE $($b.id) '$(Lbl $b)' porte $([int]$m.deg[$b.id]) lien(s), la legende en exige au moins $seuilBlanc" }
    }
  }
  $f
}
# Le seuil de la regle blanche est LU DANS LA LEGENDE, pas ecrit ici. Sinon la
# regle existe a deux endroits et les deux peuvent diverger -- ce qui est
# precisement le defaut que ce fichier existe pour attraper. Si la phrase n'est
# pas trouvee, on ne devine pas : on le dit et la regle ne s'applique pas.
function SeuilBlanc($m) {
  $cell = @($m.vertices | Where-Object { $_.text -and ([string]$_.value) -match 'coloured this way' }) | Select-Object -First 1
  if (-not $cell) { return -1 }
  $txt = ((([string]$cell.value) -replace '<[^>]+>', ' ') -replace '\s+', ' ')
  if ($txt -notmatch 'WHITE box must carry at least (\w+) link') { return -1 }
  switch ($Matches[1].ToLower()) {
    'one'   { 1 }  'two'   { 2 }  'three' { 3 }  'four'  { 4 }
    default { if ($Matches[1] -match '^\d+$') { [int]$Matches[1] } else { -1 } }
  }
}

function R5_Subdivisions($m) {
  # La legende distingue elle-meme les deux cas de "sans remplissage" : un
  # CONTENEUR, ou une SUBDIVISION de son parent. Le depart se lit dans le
  # parent : un cadre n'a pas de remplissage (rtapi_app), une boite subdivisee
  # en a un (le triplet NML, milltask, le fil servo). Atterrir sur la
  # subdivision d'une boite PLEINE affirme un canal precis ; c'est ce que la
  # note (12) de la planche promet de ne pas faire.
  $f = @()
  foreach ($e in $m.edges) {
    foreach ($k in @($e.src, $e.dst)) {
      if (-not $k -or -not $m.vById.ContainsKey($k)) { continue }
      $v = $m.vById[$k]
      if (-not $m.vById.ContainsKey($v.parent)) { continue }
      $p = $m.vById[$v.parent]
      if ($p.fill -and $p.fill -ne 'none') {
        $f += "arete $($e.id) atterrit sur $($k) '$(Lbl $v)', une SUBDIVISION de $($p.id) '$(Lbl $p)' : elle affirme un compartiment precis"
      }
    }
  }
  $f
}

function R6_FrontieresContreBoites($m) {
  $f = @()
  foreach ($r in $m.rules) {
    foreach ($b in (Boxes $m)) {
      if (SegCrossesBox $r $b) {
        $f += "la frontiere $($r.id) (y=$($r.y1)) traverse la boite $($b.id) '$(Lbl $b)'"
      }
    }
  }
  $f
}

function R7_LibellesDAretes($m) {
  $f = @()
  foreach ($e in $m.edges) {
    if ($e.value) {
      $t = ((([string]$e.value) -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
      $f += "arete $($e.id) porte le libelle '$t' : le convertisseur ne l'emet PAS, donc le PNG et la planche HTML ne diront pas la meme chose"
    }
  }
  $f
}

function R8_ConvertToSvg($m) {
  # La propriete derriere la case "Convert Labels to SVG" (Format > Texte >
  # Avance). Sans elle, draw.io ecrit le libelle en HTML dans un <foreignObject>
  # et pose a cote un <text> de repli TRONQUE : un libelle de trois lignes sort
  # en "INI file...". Un navigateur affiche le HTML et personne ne voit rien ;
  # un moteur qui n'implemente pas l'extension affiche la troncature.
  #
  # DEUX defauts, pas un, et le second est mesure : posee EN TETE de style la
  # propriete ne prend pas -- le premier jeton d'un style mxGraph peut etre un
  # nom de feuille -- et deux formes sur cinquante-six avaient garde leur
  # foreignObject de cette facon. Elle se pose en FIN de style.
  #
  # CE QUE CETTE REGLE NE PROUVE PAS, et c'est important : que la conversion ait
  # eu lieu. La documentation de draw.io limite la case aux libelles a balises
  # simples et l'exclut des tableaux, listes, liens et fonds colores ; elle est
  # alors grisee, et rien dans l'export ne le signale. Le seul controle qui
  # prouve est de compter les <foreignObject> APRES export -- il n'appartient pas
  # a cet outil, qui ne lit que le modele. Le README de ce depot le dit et donne
  # la commande, dans la section consacree au SVG engendre.
  $f = @()
  foreach ($c in @($m.vertices) + @($m.edges) + @($m.rules)) {
    $st = [string]$c.style
    if ($st -notmatch 'convertToSvg=1') {
      $f += "cellule $($c.id) '$(Lbl $c)' ne porte pas convertToSvg=1 : son libelle sortira en foreignObject, avec un repli tronque"
    } elseif ($st -match '^convertToSvg=1') {
      $f += "cellule $($c.id) '$(Lbl $c)' porte convertToSvg=1 EN TETE de style, ou il ne prend pas : le poser en fin"
    }
  }
  $f
}

# ---------- non-vacuite : chaque regle doit d'abord echouer -------------------
function AutoTest($m) {
  $mauvais = @()
  $clone = { param($src) Build ([IO.File]::ReadAllText($src)) }

  # R1 : une arete sans cible
  $t = & $clone $Path
  $t.edges += [pscustomobject]@{ id='TEST'; src=$t.vertices[0].id; dst=''; value=''; style='' }
  if ((R1_AretesPendantes $t).Count -eq 0) { $mauvais += 'R1 ne detecte pas une arete sans cible' }

  # R2 : une boite de premier niveau sans lien
  $t = & $clone $Path
  $t.vertices += [pscustomobject]@{ id='TEST'; parent='1'; style=''; value='temoin'; x=0;y=0;w=10;h=10; lx=0;ly=0; text=$false; fill='#fff'; container=$false; detached=$false }
  if ((R2_BoitesOrphelines $t).Count -eq 0) { $mauvais += 'R2 ne detecte pas une boite orpheline' }

  # R3 : un enfant deplace hors de son parent
  $t = & $clone $Path
  $enfant = @($t.vertices | Where-Object { $t.vById.ContainsKey($_.parent) }) | Select-Object -First 1
  if ($enfant) { $enfant.x = $enfant.x - 100000 }
  if ((R3_ParentContredit $t).Count -eq 0) { $mauvais += 'R3 ne detecte pas un enfant hors de son parent' }

  # R4 : une boite verte sortie de rtapi_app
  $t = & $clone $Path
  $v = @(Boxes $t | Where-Object { $_.fill -eq '#d5e8d4' }) | Select-Object -First 1
  if ($v) { $v.y = $v.y - 100000 }
  if ((R4_Couleurs $t).Count -eq 0) { $mauvais += 'R4 ne detecte pas une boite verte hors de rtapi_app' }

  # R5 : une arete visant une subdivision
  $t = & $clone $Path
  $sub = @($t.vertices | Where-Object { $t.vById.ContainsKey($_.parent) -and $t.vById[$_.parent].container }) | Select-Object -First 1
  if ($sub) { $t.edges += [pscustomobject]@{ id='TEST'; src=$sub.id; dst=$sub.id; value=''; style='' } }
  if ((R5_Subdivisions $t).Count -eq 0) { $mauvais += 'R5 ne detecte pas une arete visant une subdivision' }

  # R6 : une frontiere allongee sur toute la largeur
  $t = & $clone $Path
  if ($t.rules.Count) { $t.rules[0].x2 = 999999 }
  if ((R6_FrontieresContreBoites $t).Count -eq 0) { $mauvais += 'R6 ne detecte pas une frontiere traversant une boite' }

  # R7 : un libelle pose sur une arete
  $t = & $clone $Path
  $t.edges[0].value = 'temoin'
  if ((R7_LibellesDAretes $t).Count -eq 0) { $mauvais += 'R7 ne detecte pas un libelle d arete' }

  # R8 : les DEUX defauts, separement. Un temoin unique laisserait la moitie de
  # la regle sans preuve, et c'est la moitie subtile qui a reellement mordu.
  $t = & $clone $Path
  $t.vertices[0].style = 'rounded=0;whiteSpace=wrap;html=1;'
  if ((R8_ConvertToSvg $t).Count -eq 0) { $mauvais += 'R8 ne detecte pas une forme sans convertToSvg' }
  $t = & $clone $Path
  $t.vertices[0].style = 'convertToSvg=1;rounded=0;whiteSpace=wrap;html=1;'
  if ((R8_ConvertToSvg $t).Count -eq 0) { $mauvais += 'R8 ne detecte pas convertToSvg pose en tete de style' }

  # Le prealable de compression, dans les DEUX SENS : un predicat qui rendrait
  # toujours vrai passerait pour un garde-fou tout en n'en etant pas un.
  # L'echantillon est court et VISIBLEMENT faux, exprès : ce qui est teste est
  # l'ABSENCE de <mxGraphModel>, jamais la validite d'une charge deflate. Y
  # coller un vrai bloc compresse le ferait passer pour un exemple a reutiliser
  # et n'ajouterait rien a la preuve.
  if (-not (EstCompresse '<mxfile host="Electron"><diagram id="a">[base64+deflate, opaque]</diagram></mxfile>')) {
    $mauvais += 'le prealable ne reconnait pas un modele compresse'
  }
  if (EstCompresse $texte) { $mauvais += 'le prealable declare compresse un modele en clair' }

  $mauvais
}

# ---------- execution --------------------------------------------------------
# $texte est deja lu plus haut, par le prealable de compression.
$m = Build $texte

# La liste est definie AVANT l'auto-test pour que le compte annonce vienne
# d'elle et non d'un nombre ecrit a la main : la ligne disait "les 7 regles"
# quand il y en avait sept, et serait devenue fausse en en ajoutant une.
$regles = @(
  @{ n='R1 aretes pendantes';            f={ R1_AretesPendantes $m } },
  @{ n='R2 boites orphelines';           f={ R2_BoitesOrphelines $m } },
  @{ n='R3 parent contredit par la geo'; f={ R3_ParentContredit $m } },
  @{ n='R4 regles de couleur';           f={ R4_Couleurs $m } },
  @{ n='R5 subdivisions visees';         f={ R5_Subdivisions $m } },
  @{ n='R6 frontieres contre boites';    f={ R6_FrontieresContreBoites $m } },
  @{ n='R7 libelles d aretes';           f={ R7_LibellesDAretes $m } },
  @{ n='R8 convertToSvg sur les styles'; f={ R8_ConvertToSvg $m } }
)

$echecsAutoTest = AutoTest $m
if ($echecsAutoTest.Count) {
  Write-Output 'REFUSE : le verificateur est casse, une regle ne sait pas echouer.'
  $echecsAutoTest | ForEach-Object { Write-Output ("   " + $_) }
  exit 2
}

Write-Output ("modele : " + (Split-Path $Path -Leaf))
Write-Output ("  " + (Boxes $m).Count + " boites, " + @($m.vertices | Where-Object { $_.text }).Count + " libelles libres, " + $m.edges.Count + " aretes, " + $m.rules.Count + " frontieres")
Write-Output ("  auto-test : les " + $regles.Count + " regles ont echoue sur leur mutation temoin,")
Write-Output ("              et le prealable de compression discrimine dans les deux sens")
Write-Output ''

$total = 0
foreach ($r in $regles) {
  $f = & $r.f
  $total += $f.Count
  if ($f.Count -eq 0) { Write-Output ("  OK    " + $r.n) }
  else {
    Write-Output ("  ECHEC " + $r.n + " (" + $f.Count + ")")
    $f | ForEach-Object { Write-Output ("          " + $_) }
  }
}

Write-Output ''
if ($total -eq 0) { Write-Output 'VERDICT : propre.' } else { Write-Output ("VERDICT : $total probleme(s).") }
Write-Output ''
Write-Output 'Hors de portee de cet outil : le trace des connecteurs (draw.io le calcule au rendu),'
Write-Output 'la largeur rendue des textes (le modele n a pas la police), et la question de savoir'
Write-Output 'si la figure est vraie. Les deux premiers se regardent sur la toile draw.io ; le'
Write-Output 'troisieme ne se regarde nulle part, aucun script ne repond a cela.'
exit $(if ($total -eq 0) { 0 } else { 1 })
