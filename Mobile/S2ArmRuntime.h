#import <UIKit/UIKit.h>

int gc_s2arm_available(void);
int gc_s2arm_active(void);
int gc_s2arm_release_va_window(void);
const char *gc_s2arm_start_game(const char *title_id);
void gc_nx_set_library_controller(UIViewController *controller);
void gc_nx_focus(int state);
UIInterfaceOrientationMask gc_nx_orientations(UITraitCollection *traits);
