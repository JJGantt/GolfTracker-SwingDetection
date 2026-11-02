-- How the watch was worn when the motion was recorded.
--
-- Uploaded motion files stay in the watch's hardware frame, which depends on
-- the wrist and on which side the crown faces (`WKInterfaceDevice.wristLocation`
-- / `crownOrientation`). Without these a recording cannot be re-expressed in
-- the frame the detector's thresholds were measured on (left wrist, crown on
-- the right). NULL means the uploading build did not record it.
alter table swing_events
    add column if not exists wrist text,
    add column if not exists crown text;

alter table swing_events
    add constraint swing_events_wrist_check check (wrist in ('left', 'right')),
    add constraint swing_events_crown_check check (crown in ('left', 'right'));

alter table false_negative_groups
    add column if not exists wrist text,
    add column if not exists crown text;

alter table false_negative_groups
    add constraint false_negative_groups_wrist_check check (wrist in ('left', 'right')),
    add constraint false_negative_groups_crown_check check (crown in ('left', 'right'));

comment on column swing_events.wrist is
    'Wrist the watch was worn on (WKInterfaceDevice.wristLocation): left or right. NULL when not recorded.';
comment on column swing_events.crown is
    'Side the crown faced as the wearer looks at the watch (WKInterfaceDevice.crownOrientation): left or right. NULL when not recorded.';
comment on column false_negative_groups.wrist is
    'Wrist the watch was worn on (WKInterfaceDevice.wristLocation): left or right. NULL when not recorded.';
comment on column false_negative_groups.crown is
    'Side the crown faced as the wearer looks at the watch (WKInterfaceDevice.crownOrientation): left or right. NULL when not recorded.';
