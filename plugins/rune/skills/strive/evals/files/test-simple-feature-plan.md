---
title: Add User Profile Avatar
status: ready
priority: P2
complexity: S
---

# Add User Profile Avatar

## Overview
Add avatar upload and display functionality to user profiles.

## Tasks

### Task 1: Backend Avatar Upload Endpoint
- [ ] Create POST /api/users/avatar endpoint
- [ ] Add multipart/form-data handling
- [ ] Validate file size (max 2MB)
- [ ] Validate file type (jpg, png, gif)
- [ ] Store file in /uploads/avatars/{user_id}.{ext}

**Files**: src/api/users.py, src/services/avatar_service.py

### Task 2: Frontend Avatar Component
- [ ] Create AvatarUpload component with drag-drop
- [ ] Create AvatarDisplay component
- [ ] Add preview before upload
- [ ] Handle upload progress

**Files**: src/components/AvatarUpload.tsx, src/components/AvatarDisplay.tsx

### Task 3: Unit Tests
- [ ] Test avatar upload endpoint
- [ ] Test file validation
- [ ] Test avatar components

**Files**: tests/api/test_avatar.py, tests/components/AvatarUpload.test.tsx