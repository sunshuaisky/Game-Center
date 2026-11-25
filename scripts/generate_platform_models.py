import bpy, math, os
from mathutils import Vector
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT=os.path.join(ROOT,'Sources','GameCenter','Resources')
# fresh scene
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
for d in bpy.data.materials: bpy.data.materials.remove(d)
# helpers
def linear(v):
    v=v/255
    return v/12.92 if v<0.04045 else ((v+0.055)/1.055)**2.4
def mat(name, rgb, metal=0.0, rough=.35, emission=None):
    m=bpy.data.materials.new(name); m.diffuse_color=(*[linear(c) for c in rgb],1); m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF'); p.inputs['Base Color'].default_value=(*[linear(c) for c in rgb],1); p.inputs['Metallic'].default_value=metal; p.inputs['Roughness'].default_value=rough
    if emission:
        p.inputs['Emission Color'].default_value=(*[linear(c) for c in rgb],1); p.inputs['Emission Strength'].default_value=emission
    return m
MAT={
'black':mat('Soft black • ceramic', (24,27,33),.16,.26), 'dark':mat('Deep graphite', (9,12,17),.12,.22), 'glass':mat('Smoked glass', (9,19,28),.27,.16),
'screen':mat('Idle LCD', (7,15,22),.04,.18), 'shine':mat('Glass reflection', (100,177,193),.2,.18,.12), 'metal':mat('Satin aluminium',(154,165,177),.72,.25),
'white':mat('Warm white polymer',(224,221,210),.02,.42), 'gray':mat('Cool gray polymer',(95,106,122),.035,.48), 'silver':mat('Console silver',(132,145,160),.12,.40),
'purple':mat('Indigo polymer',(94,72,151),.1,.27), 'violet':mat('Violet controls',(110,69,155),.08,.24), 'red':mat('Signal red',(193,61,70),.1,.24),
'blue':mat('Cobalt blue',(54,130,211),.13,.24), 'cyan':mat('Cool cyan',(81,176,188),.1,.27), 'teal':mat('Sea glass',(106,181,173),.12,.28),
'yellow':mat('Warm yellow',(222,184,81),.09,.28), 'green':mat('Forest green',(80,126,95),.1,.29), 'button':mat('Button charcoal',(44,47,55),.18,.24), 'label':mat('Soft label',(184,191,198),.1,.35),
'pink':mat('Soft rose',(194,98,119),.1,.26), 'orange':mat('Muted orange',(196,117,65),.08,.28), 'snes1':mat('SNES lavender',(172,174,192),.14,.27), 'snes2':mat('SNES violet',(130,112,169),.12,.25),
}
def bevel(obj, amount=.04, seg=5):
    if amount:
      mod=obj.modifiers.new('Soft molded edges','BEVEL'); mod.width=amount; mod.segments=seg
      mod2=obj.modifiers.new('Weighted corner normals','WEIGHTED_NORMAL'); mod2.keep_sharp=True; mod2.weight=40
    return obj
def box(name, loc, size, material, edge=.035, rot=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc); o=bpy.context.object; o.name=name; o.dimensions=size; bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if rot: o.rotation_euler=rot
    if material:o.data.materials.append(MAT[material] if isinstance(material,str) else material)
    bevel(o,edge); return o
def cyl(name, loc, radius, depth, material, bevel_amt=.008, rot=(math.pi/2,0,0), vertices=64):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=loc, rotation=rot); o=bpy.context.object; o.name=name
    if material:o.data.materials.append(MAT[material] if isinstance(material,str) else material)
    bevel(o,bevel_amt,3)
    for p in o.data.polygons:p.use_smooth=True
    return o
def torus(name, loc, major, minor, material, rot=(0,0,0)):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=64, minor_segments=12, location=loc, rotation=rot); o=bpy.context.object; o.name=name; o.data.materials.append(MAT[material]);
    for p in o.data.polygons:p.use_smooth=True
    return o
def text(name, body, loc, size, material, front=True):
    cv=bpy.data.curves.new(name,'FONT'); cv.body=body; cv.size=size; cv.align_x='CENTER'; cv.align_y='CENTER'; cv.extrude=.0008; cv.bevel_depth=.0005; cv.bevel_resolution=2
    o=bpy.data.objects.new(name,cv); bpy.context.collection.objects.link(o); o.location=loc
    if front:o.rotation_euler[0]=math.pi/2
    o.data.materials.append(MAT[material]); return o
def face_y(depth,z=0): return -depth/2-.012
def screen(name, x,z,w,h, bodydepth, border='black', color='glass'):
    y=-bodydepth/2-.016
    box(name+' bezel',(x,y,z),(w,.055,h),border,min(w,h)*.06)
    box(name+' glass',(x,y-.031,z),(w-.065,.012,h-.065),color,min(w,h)*.035)
    # softly lit glass glint
    box(name+' reflection',(x-w*.20,y-.039,z+h*.29),(w*.42,.004,.012),'shine',.004)
def dpad(x,z,y,scale=1, col='button'):
    box('D-pad vertical',(x,y,z),(.075*scale,.045,.235*scale),col,.025*scale)
    box('D-pad horizontal',(x,y-.003,z),(.235*scale,.046,.075*scale),col,.025*scale)
    cyl('D-pad center',(x,y-.03,z),.052*scale,.013,col,.004)
def button(name,x,z,y,r=.055,col='red'):
    cyl(name+' socket',(x,y+.014,z),r*1.25,.026,'dark',.008)
    cyl(name,(x,y-.006,z),r,.034,col,.008)
    cyl(name+' inset',(x,y-.027,z),r*.57,.008,col,.003)
def speaker(x,z,y,rows=3,cols=5,gap=.034):
    for r in range(rows):
        for c in range(cols): cyl('Speaker perforation',(x+(c-(cols-1)/2)*gap,y,z+(r-(rows-1)/2)*gap),.007,.008,'dark',.002,vertices=16)
def vent_row(x0,x1,z,y,count=12,spacing=None):
    if spacing is None: spacing=(x1-x0)/max(1,count-1)
    for i in range(count):
        x=x0+i*spacing
        box('Molded ventilation slot',(x,y,z),(.012,.006,.052),'dark',.005)
def seam_box(name, loc, size, mat_name='dark', edge=.012):
    return box(name,loc,size,mat_name,edge)
def make_gba():
    # Original horizontal AGB silhouette: tapered shoulders and a low, wide front shell.
    box('GBA rear housing',(0,.025,0),(1.56,.20,.72),'purple',.14)
    box('GBA front face',(0,-.092,0),(1.52,.055,.68),'purple',.135)
    box('Upper shoulder bridge',(0,-.008,.295),(1.22,.13,.105),'purple',.045)
    screen('GBA recessed LCD',-.14,.075,.68,.43,.19,'dark','screen')
    # Lens frame and status marks reproduce the face layout of the AGB-001.
    box('LCD lower label strip',(-.14,-.126,-.19),(.48,.012,.032),'black',.012)
    text('GBA display label','COLOR',(-.14,-.135,-.19),.019,'label')
    dpad(-.55,-.16,-.124,.82,'black')
    button('B',.43,-.17,-.125,.057,'pink'); button('A',.62,-.10,-.125,.057,'pink')
    box('SELECT',(-.12,-.12,-.27),(.15,.025,.040),'button',.018,(0,0,-.15)); box('START',(.09,-.12,-.27),(.15,.025,.040),'button',.018,(0,0,-.15))
    # Raised L/R shoulder keys and cartridge access seam.
    for x in [-.55,.55]: box('L/R shoulder key',(x,.015,.365),(.28,.17,.062),'gray',.028)
    seam_box('Cartridge access seam',(0,.12,.335),(.58,.018,.026),'dark',.009)
    speaker(.05,-.10,-.125,2,6,.032)
    text('GBA mark','GAME BOY ADVANCE',(0,-.126,.265),.045,'label')
def make_gb(gbc=False):
    shell='teal' if gbc else 'gray'
    # Tall DMG / Color shell with a deep, slightly green-tinted LCD recess.
    box('Handheld rear shell',(0,.025,0),(.79,.16,1.30),shell,.095)
    box('Handheld front shell',(0,-.072,0),(.77,.055,1.28),shell,.09)
    box('Display surround',(0,-.113,.32),(.59,.035,.48),'black',.055)
    box('LCD lens',(0,-.136,.32),(.51,.012,.37),'screen',.03)
    box('LCD reflection',(-.12,-.144,.43),(.24,.004,.010),'shine',.003)
    text('Model mark','GAME BOY COLOR' if gbc else 'DOT MATRIX WITH STEREO SOUND',(0,-.139,.59),.027,'label')
    dpad(-.22,-.22,-.12,.70,'black')
    button('B',.18,-.23,-.12,.061,'violet' if gbc else 'red'); button('A',.36,-.18,-.12,.061,'violet' if gbc else 'red')
    box('SELECT',(-.12,-.115,-.43),(.14,.022,.040),'button',.018,(0,0,-.13)); box('START',(.11,-.115,-.43),(.14,.022,.040),'button',.018,(0,0,-.13))
    # Speaker grille, power slider, contrast wheel and molded side seam.
    speaker(-.05,-.57,-.12,2,7,.032)
    box('Power switch',(.30,-.035,.65),(.13,.075,.055),'dark',.018)
    box('Power slider',(.30,-.078,.65),(.065,.014,.030),'gray',.008)
    cyl('Contrast dial',(-.29,-.074,.63),.043,.024,'button',.008)
    seam_box('Shell parting line',(0,.102,0),(.72,.008,1.14),'gray',.003)
def make_nds(three=False):
    shell='blue' if three else 'black'
    # two clamshell halves, hinge exposed; raised hinge cylinder running sideways
    box('Lower body',(0,-.015,-.40),(1.17,.18,.65),shell,.075)
    box('Lower inner face',(0,-.119,-.40),(1.08,.025,.57),shell,.055)
    box('Upper lid',(0,.075,.40),(1.17,.15,.66),shell,.085, (math.radians(-6),0,0))
    box('Upper lid inset',(0,-.012,.40),(1.06,.018,.55),shell,.055, (math.radians(-6),0,0))
    cyl('Hinge',(0,.055,0),.075,1.00,'black',.012,(0,math.pi/2,0))
    screen('Lower touchscreen',0,-.39,.82,.44,.18,'dark','glass')
    screen('Upper screen',0,.39,.86,.48,.15,'dark','screen')
    if three:
      cyl('3D camera center',(0,-.013,.72),.022,.012,'dark',.004)
      cyl('3D camera left',(-.065,-.013,.72),.019,.012,'dark',.004)
      cyl('3D camera right',(.065,-.013,.72),.019,.012,'dark',.004)
      cyl('Circle pad',(-.39,-.137,-.30),.082,.035,'gray',.012)
      torus('Circle pad ring',(-.39,-.139,-.30),.068,.007,'black',(math.pi/2,0,0))
      dpad(-.39,-.54,-.13,.62,'black')
      button('A',.40,-.28,-.13,.039,'red'); button('B',.32,-.36,-.13,.039,'red'); button('X',.32,-.20,-.13,.039,'red'); button('Y',.24,-.28,-.13,.039,'red')
      box('3DS volume rail',(.555,-.08,.28),(.025,.04,.23),'gray',.01)
      for x in [-.43,0,.43]: cyl('Camera lens',(x,-.026,.70),.018,.012,'dark',.003)
      text('Nintendo mark','3D',(0,-.014,.70),.035,'label')
    else:
      dpad(-.39,-.50,-.13,.62,'gray')
      button('A',.39,-.35,-.13,.04,'pink'); button('B',.30,-.43,-.13,.04,'pink'); button('X',.30,-.27,-.13,.04,'pink'); button('Y',.21,-.35,-.13,.04,'pink')
      box('Stylus slot',(.49,-.117,-.16),(.035,.018,.30),'gray',.014)
      box('Stylus end',(.49,-.13,-.02),(.030,.012,.035),'black',.009)
      cyl('DS microphone',(.0,-.13,-.67),.018,.008,'dark',.003)
    text('DualScreen mark','NINTENDO 3DS' if three else 'NINTENDO DS',(0,-.114,-.14),.034,'label')
def make_psp():
    box('PSP rear shell',(0,.025,0),(1.68,.19,.75),'black',.18)
    box('PSP front fascia',(0,-.09,0),(1.63,.045,.71),'black',.16)
    screen('PSP screen',0,.015, .96,.54,.18,'dark','screen')
    dpad(-.59,-.18,-.12,.68,'gray')
    cyl('Analog socket',(-.55,-.119,.20),.10,.028,'dark',.009); cyl('Analog cap',(-.55,-.145,.20),.068,.04,'gray',.014)
    for n,x,z,c in [('triangle',.62,.20,'green'),('circle',.72,.08,'blue'),('cross',.51,.08,'cyan'),('square',.62,-.04,'pink')]: button(n,x,z,-.105,.035,c)
    speaker(-.77,0,-.12,5,1,.028); speaker(.77,0,-.12,5,1,.028)
    text('PSP mark','SONY',(0,-.121,.32),.045,'label')
    seam_box('UMD door seam',(0,.12,-.02),(1.16,.01,.55),'gray',.18)
    box('Power and hold switch',(.78,-.06,-.26),(.18,.045,.07),'gray',.025)
def make_famicom():
    box('Famicom body',(0,0,0),(1.52,.21,.92),'white',.09)
    box('Red upper panel',(0,-.115,.04),(1.32,.035,.70),'red',.045)
    box('Cartridge opening',(0,-.139,.10),(.56,.018,.28),'dark',.035)
    box('Cartridge lip',(0,-.152,.26),(.58,.018,.08),'gray',.02)
    for x in [-.52,.52]:
      cyl('Power control',(x,-.147,-.22),.055,.025,'white',.008)
    text('Famicom logo','FAMILY COMPUTER',(0,-.142,-.34),.074,'white')
    # iconic permanently tethered red gamepads along the front edge
    for x in [-.45,.45]:
      box('Famicom wired controller',(x,-.19,-.48),(.48,.055,.21),'red',.035)
      if x<0: dpad(x-.12,-.48,-.225,.46,'white')
      else: button('B',x-.09,-.48,-.225,.034,'white'); button('A',x+.06,-.44,-.225,.034,'white')
      box('Select', (x-.025,-.225,-.54),(.10,.015,.022),'white',.008)
      # twin cables as curves
      cu=bpy.data.curves.new('Controller tether','CURVE'); cu.dimensions='3D'; cu.bevel_depth=.009; cu.bevel_resolution=3
      sp=cu.splines.new('BEZIER'); sp.bezier_points.add(2)
      for bp,co in zip(sp.bezier_points,[(x,-.15,-.46),(x*1.18,-.04,-.54),(x*1.23,-.04,-.25)]): bp.co=co; bp.handle_left_type='AUTO'; bp.handle_right_type='AUTO'
      ob=bpy.data.objects.new('Red controller cable',cu); bpy.context.collection.objects.link(ob); ob.data.materials.append(MAT['red'])
def make_sfc():
    box('Super Famicom case',(0,0,0),(1.50,.25,.96),'snes1',.16)
    box('Cartridge bay',(0,-.137,-.02),(.63,.035,.42),'gray',.11)
    box('Cartridge slot',(0,-.16,.02),(.43,.014,.22),'dark',.06)
    box('Eject key',(0,-.16,-.29),(.22,.035,.085),'snes2',.035)
    for x,c in [(-.59,'gray'),(-.40,'red')]: button('Power/reset',x,.34,-.14,.055,c)
    text('Super Famicom mark','SUPER FAMICOM',(0,-.155,.37),.057,'label')
    # SNES pad silhouette, button colors
    box('Controller pad',(0,-.19,-.66),(.80,.09,.31),'gray',.08)
    dpad(-.25,-.66,-.245,.56,'black')
    for x,z,c in [(.18,-.60,'blue'),(.30,-.69,'green'),(.18,-.76,'yellow'),(.06,-.69,'pink')]: button('SNES face',x,z,-.245,.035,c)
    text('SNES mark','Nintendo',(0,-.25,-.65),.035,'label')
def make_n64():
    box('N64 console',(0,0,0),(1.28,.43,1.05),'gray',.20)
    box('Cartridge slot',(0,-.025,.24),(.55,.12,.31),'dark',.065)
    box('Game pak',(0,-.025,.48),(.46,.11,.39),'green',.055)
    box('Cartridge label',(0,-.087,.47),(.30,.008,.22),'label',.018)
    text('N64 label','N64',(0,-.094,.47),.085,'black')
    box('Front port panel',(0,-.22,-.39),(.92,.035,.11),'dark',.035)
    for x in [-.33,-.11,.11,.33]: cyl('Controller socket',(x,-.247,-.39),.047,.018,'metal',.006)
    button('Power',-.49,-.42,-.225,.052,'red')
    box('Reset key',(.49,-.222,-.42),(.12,.045,.09),'black',.035)
def make_md():
    box('Mega Drive case',(0,0,0),(1.38,.42,1.13),'black',.17)
    # concentric circular top insignia and 16-bit bezel
    cyl('Upper emblem surround',(0,-.04,.27),.36,.10,'dark',.025,(0,0,0))
    torus('Upper emblem ring',(0,-.04,.323),.28,.018,'silver')
    cyl('Upper emblem',(0,-.04,.32),.25,.025,'gray',.008,(0,0,0))
    text('16 bit badge','16-BIT',(0,-.04,.339),.09,'black',front=False)
    box('Cartridge mouth',(0,-.02,-.31),(.72,.08,.27),'dark',.06)
    box('Cartridge guide',(0,-.02,-.22),(.62,.08,.12),'gray',.025)
    box('Front trim',(0,-.215,-.48),(1.00,.045,.10),'dark',.035)
    button('Power',-.52,-.48,-.23,.055,'red'); button('Reset',-.34,-.48,-.23,.046,'gray')
    text('Sega mark','SEGA',(0,-.241,-.47),.055,'label')
def make_ps1():
    box('PlayStation shell',(0,0,0),(1.34,.38,1.30),'silver',.18)
    cyl('Disc tray lid',(0,-.008,.20),.46,.055,'gray',.035,(0,0,0))
    torus('Disc lid ring',(0,-.008,.231),.36,.012,'silver')
    cyl('Disc hub',(0,-.008,.237),.095,.016,'metal',.01,(0,0,0))
    box('Front panel',(0,-.204,-.50),(.96,.035,.10),'gray',.028)
    for x in [-.35,.35]: box('Memory card slot',(x,-.23,-.48),(.23,.025,.065),'dark',.014)
    button('Power',-.51,-.49,-.22,.056,'blue'); button('Reset',-.34,-.49,-.22,.046,'gray')
    text('PlayStation mark','PlayStation',(0,-.23,.60),.07,'label',front=False)
def make_switch():
    box('Switch tablet',(0,0,0),(1.18,.16,.76),'black',.085)
    screen('Switch glass',0,0,1.02,.61,.16,'dark','screen')
    # joycon bodies are joined visually to either edge of the tablet
    box('Left Joy-Con',(-.72,-.015,0),(.25,.18,.80),'blue',.095)
    box('Right Joy-Con',(.72,-.015,0),(.25,.18,.80),'red',.095)
    cyl('Left stick',(-.72,-.112,.20),.065,.035,'black',.009)
    dpad(-.72,-.20,-.11,.49,'black')
    cyl('Right stick',(.72,-.112,-.18),.061,.035,'black',.008)
    for n,x,z in [('A',.77,.20),('B',.66,.11),('X',.66,.29),('Y',.55,.20)]: button('Joy-Con '+n,x,z,-.11,.026,'white')
    text('Nintendo logo','NINTENDO SWITCH',(0,-.108,-.34),.046,'label')
def make_mac():
    box('MacBook lower shell',(0,.05,0),(1.55,1.00,.095),'metal',.055)
    box('Keyboard deck',(0,-.02,.056),(1.24,.56,.018),'gray',.03)
    for row in range(4):
      for col in range(12): box('Key',( -.53+col*.096,-.20+row*.105,.069),(.067,.072,.014),'black',.009)
    box('Trackpad',(0,.32,.069),(.44,.27,.012),'silver',.025)
    # vertical display lid, tilted slightly back
    lid=box('MacBook display',(0,.47,.54),(1.55,.075,.94),'metal',.065,(math.radians(-7),0,0))
    screen('Retina display',0,.54,1.37,.78,.075,'black','screen')
    text('Apple mark','●',(0,.508,.54),.14,'silver')
    # native-app-inspired subtle pixel artwork on screen
    for i,c in enumerate(['blue','violet','pink','teal']): box('Game tile',( -.36+i*.24,.499,.48),(.18,.012,.24),c,.025)
# clear all objects between models, set origin near center for import
builders={'platform-gba':make_gba,'platform-gb':lambda:make_gb(False),'platform-gbc':lambda:make_gb(True),'platform-nds':lambda:make_nds(False),'platform-3ds':lambda:make_nds(True),'platform-psp':make_psp,'platform-fc':make_famicom,'platform-sfc':make_sfc,'platform-n64':make_n64,'platform-md':make_md,'platform-ps1':make_ps1,'platform-switch':make_switch,'platform-mac':make_mac}
for name,build in builders.items():
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
    build()
    # apply transforms and weighted normals to avoid exporter differences
    for o in list(bpy.context.scene.objects):
      if o.type=='MESH':
        bpy.context.view_layer.objects.active=o
        for m in list(o.modifiers):
          try: bpy.ops.object.modifier_apply(modifier=m.name)
          except: pass
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(filepath=f'{OUT}/{name}.glb', export_format='GLB', use_selection=True, export_apply=True, export_yup=True, export_animations=False)
    print('Exported',name)
