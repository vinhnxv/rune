---
title: Add user profile avatar upload
type: feature
complexity: standard
created: 2026-03-01
---

# Add User Profile Avatar Upload

## Summary

Allow users to upload profile avatars with image validation, cropping, and CDN storage.

## Tasks

### Task 1: Avatar Upload API Endpoint
- Create `POST /api/users/:id/avatar` endpoint
- Accept multipart/form-data with image file
- Validate file type (JPEG, PNG, WebP) and size (max 5MB)
- Store to S3-compatible storage

### Task 2: Image Processing Pipeline
- Resize to standard dimensions (128x128, 256x256, 512x512)
- Generate WebP variants for browser optimization
- Create placeholder blur hash for lazy loading

### Task 3: Frontend Upload Component
- Drag-and-drop upload zone with preview
- Client-side image cropping before upload
- Progress indicator during upload
- Error handling for invalid files

### Task 4: Database Schema Update
- Add `avatar_url` and `avatar_blurhash` columns to users table
- Migration with rollback support
- Update user serializer to include avatar fields

## Dependencies
- S3-compatible storage (MinIO for local dev)
- sharp library for image processing

## Acceptance Criteria
- [ ] Users can upload JPEG, PNG, or WebP images
- [ ] Images are resized to 3 standard sizes
- [ ] Upload shows progress and handles errors
- [ ] Avatar URL is stored and returned in user API responses
