# Air Workflow Guide

## Overview

<!-- TODO: Customize this section to describe your project's specific workflow -->
Air implements a planning-first workflow where planning documents serve as the single source of truth for requirements and specifications. The workflow ensures that execution follows documented design and that progress is trackable through document states.

## Core Workflow Principles

### Filesystem as Database
<!-- TODO: Adapt these principles to your project's workflow -->
- All project planning lives in files and directories
- No complex databases or external tools required
- Works with any text editor and file explorer
- Git integration provides optional versioning and timestamp tracking

### Planning-First Workflow
<!-- TODO: Customize these steps based on your project's process -->
1. **Plan First**: Create Air documents before executing work
2. **Specify Completely**: Move documents to 'ready' state only when fully specified
3. **Track Progress**: Use document states to monitor progress
4. **Document Execution**: Update History as work progresses

## Document Lifecycle

### State Progression
Documents follow this typical progression through states:

```
draft → ready → work-in-progress → complete
   ↓                                  ↓
dropped                           archive/
```

### State Transitions

#### From Draft to Ready
- Complete all required sections (Summary, Motivation, Proposal)
- Ensure specification is actionable
- Get stakeholder review and approval
- All dependencies should be identified

#### From Ready to Work-in-Progress  
- Begin execution
- Update state immediately when starting
- Add History entry with start date

#### From Work-in-Progress to Complete
- Execution finished according to specification
- All validation passing (if applicable)
- Documentation updated to reflect any design changes
- History updated with completion details

#### Dropping Documents
- Mark as 'dropped' when no longer needed
- Add History entry explaining why
- Consider moving to archive/ if referenced elsewhere

## Working with Air Documents

### Creating New Documents

1. **Check Existing Documents**: Search for similar or related specifications first
2. **Choose Location**: Place in appropriate version directory (v0.1/, v0.2/, etc.)
3. **Use Template**: Copy from `./air/templates/` if available
4. **Set Initial State**: Start with `#+state: draft`
5. **Add Metadata**: Include title and relevant tags

<!-- TODO: Add project-specific document creation guidelines -->

### Required Document Structure

Every Air document must include:
- **Title**: Clear, descriptive document name
- **State**: Current lifecycle state
- **Summary**: Brief overview of what this addresses
- **Motivation**: Why this work is needed
- **Proposal**: Detailed specification
- **History**: Track of all work done

<!-- TODO: Add or modify sections based on your project's needs -->

### Optional Sections
<!-- TODO: Customize optional sections for your project -->
- **Goals/Non-Goals**: Scope clarification
- **Design Details**: Technical implementation specifics  
- **Infrastructure Needed**: External dependencies
- **Test Plan**: Validation approach
- **Alternatives**: Other approaches considered
- **Future Enhancements**: Post-implementation improvements

### Updating Documents

#### State Changes with airctl
```bash
# Update document state
airctl update v0.1/feature-name.org --state work-in-progress

# Update multiple properties at once
airctl update v0.1/feature-name.org --state complete --title "Updated Title"

# Add or remove tags
airctl update v0.1/feature-name.org --add-tag reviewed
airctl update v0.1/feature-name.org --remove-tag draft-only
```

#### Manual Updates
You can also manually edit document headers if preferred:
- Update `#+state:` property in document
- Add entry to History section with date and description
- Use ISO date format (YYYY-MM-DD) for consistency

#### During Execution
- Document any design changes that deviate from original spec
- Keep History current with major milestones
- Update state to 'complete' only when fully finished

#### After Completion
- Ensure History reflects final state
- Consider moving to archive/ if no longer actively referenced
- Update any dependent documents that reference this work

## Directory Organization

### Version-Based Structure
- **v0.1/**: Current milestone work
- **v0.2/**: Next milestone planning
- **archive/**: Completed or obsolete documents
- **templates/**: Document templates for consistency

### Working with Versions
- Create new version directories as project evolves
- Use semantic versioning: v0.1, v0.2, v0.10 (sorts correctly)
- Don't use version tags - organize by directory instead
- Move completed work to archive/ when stable

## Air Commands Integration

### Status Tracking
```bash
# See all work in progress
airctl status --state work-in-progress

# Check what's ready for execution
airctl status --state ready

# View specific directory progress
airctl status --directory v0.1/

# Group by tags to see feature areas
airctl status --by-tag
```

### Document Management
```bash
# Initialize Air structure
airctl init

# Show document content (TODO: not yet implemented)
airctl show v0.1/feature-name.org

# Update document metadata  
airctl update v0.1/feature-name.org --state complete

# Move documents between directories (TODO: directory moves not yet implemented)
# airctl update v0.1/completed-feature.org --directory archive/
```

### Context Generation
```bash
# Generate context files
airctl context generate

# Generate with tool integration files
airctl context generate --claude
airctl context generate --agents
airctl context generate --all
```

## Collaboration Workflow

<!-- TODO: Adapt collaboration workflow to your team structure -->

### For Team Members
1. **Check Status**: Use `airctl status` to see current work
2. **Read Specifications**: Review 'ready' documents before executing
3. **Claim Work**: Use `airctl update` to move document to 'work-in-progress'
4. **Update Progress**: Keep History current
5. **Complete Documentation**: Update state and history when finished

### For Project Leads
1. **Review Drafts**: Ensure documents are complete before marking 'ready'
2. **Track Progress**: Monitor work-in-progress items with `airctl status`
3. **Plan Releases**: Use document states to plan milestone completion
4. **Archive Management**: Move completed work to archive/ periodically

## Integration with Development Tools

### Git Workflow
- Air documents live alongside code
- Commit document updates with related code changes
- Use Air states to plan pull request scope
- Tag releases based on completed Air milestones

### AI Tool Integration
- Context files provide baseline project understanding for AI tools
- AI tools can reference Air specifications during implementation
- Edit context files directly when project conventions evolve

## Best Practices

<!-- TODO: Add project-specific best practices -->

### Planning
- Write Air documents before starting complex work
- Include clear acceptance criteria in specifications
- Identify dependencies between documents
- Review and approve documents before execution

### Execution
- Start execution only from 'ready' documents
- Update document state immediately when starting work using `airctl update`
- Document design changes that occur during execution
- Keep History current throughout work

### Maintenance
- Review document states regularly with `airctl status`
- Archive completed work that's no longer referenced
- Update specifications when requirements change
- Update context files when conventions change

## Troubleshooting

### Unknown States
If documents show 'unknown' state:
- Check document metadata format
- Ensure `#+state:` property is present and valid
- Verify file is in supported format (.org or .md)

### Missing Documents
- Use `airctl status` to see all tracked documents
- Check .gitignore isn't excluding Air files
- Verify air-config.toml points to correct directories

### Workflow Issues
- Ensure all team members understand state meanings
- Establish clear criteria for 'ready' state approval
- Regular status reviews to catch stalled work