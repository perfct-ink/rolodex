# Design Principles

1. Responsive on all devices - phones, tablets, and larger displays should be considered for all pages.
2. Native UI Components should appear consistent on all devices. If browsers affect this, all native components should be styled. This includes dialog boxes, buttons, textfields, selects (dropdowns), checkboxes, radio buttons.
3. Interactive Design - Components that the user can click on, should change when the cursor is over them. Components that the user cannot click on, should not change when mousing over.
4. View Hierarchy - Global / App / View - There should be a level of specificity when rendering views. Global or libraries is what is assumed. Then there is App-wide changes on top of the libraries. Finally, each view should take priority and override what was previously inherited.
5. Text should never reach the edge of the viewport. When it does, it implies that it was cut off. Using margin or padding to prevent this.
6. Animations should be fast (150ms). Long animations are too distracting.
7. State changes like hovering should never change the size or position of the thing being clicked. This could cause glitchy behavior. The only exception to this is if hover or click masks stay consistent.
8. Text should not be selectable on UI components that the user would never select in them. Buttons, dropdowns, icons.
9. Views only show things of value. Pagination that never has any pages should not show.
10. No invisible masks - UI component boundaries that change states (such as hover states, click states, mouse cursor) should match visible control boundaries. For example, clicking or hovering anywhere within a text field's border, including its interior padding, should alter state of text field. This includes mouse cursors and click masks.
