package buildkite

import (
	"context"

	"github.com/buildkite/buildkite-mcp-server/pkg/trace"
	"github.com/buildkite/go-buildkite/v4"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"go.opentelemetry.io/otel/attribute"
)

// AnnotationsClient describes the subset of the Buildkite client we need for annotations.
type AnnotationsClient interface {
	ListByBuild(ctx context.Context, org, pipelineSlug, buildNumber string, opts *buildkite.AnnotationListOptions) ([]buildkite.Annotation, *buildkite.Response, error)
	Create(ctx context.Context, org, pipelineSlug, buildNumber string, ac buildkite.AnnotationCreate) (buildkite.Annotation, *buildkite.Response, error)
	Delete(ctx context.Context, org, pipelineSlug, buildNumber, annotationID string) (*buildkite.Response, error)
	ListByJob(ctx context.Context, org, pipelineSlug, buildNumber, jobID string, opts *buildkite.AnnotationListOptions) ([]buildkite.Annotation, *buildkite.Response, error)
	CreateForJob(ctx context.Context, org, pipelineSlug, buildNumber, jobID string, ac buildkite.AnnotationCreate) (buildkite.Annotation, *buildkite.Response, error)
	DeleteForJob(ctx context.Context, org, pipelineSlug, buildNumber, jobID, annotationID string) (*buildkite.Response, error)
}

type ListAnnotationsArgs struct {
	OrgSlug      string `json:"org_slug"`
	PipelineSlug string `json:"pipeline_slug"`
	BuildNumber  string `json:"build_number"`
	Page         int    `json:"page,omitempty" jsonschema:"Page number for pagination (min 1)"`
	PerPage      int    `json:"per_page,omitempty" jsonschema:"Results per page for pagination (min 1\\, max 100)"`
}

type CreateAnnotationArgs struct {
	OrgSlug      string `json:"org_slug"`
	PipelineSlug string `json:"pipeline_slug"`
	BuildNumber  string `json:"build_number"`
	Body         string `json:"body" jsonschema:"The annotation body as HTML or Markdown"`
	Style        string `json:"style,omitempty" jsonschema:"Optional annotation style: success, info, warning, or error"`
	Priority     int    `json:"priority,omitempty" jsonschema:"Optional annotation priority from 1 to 10"`
	Context      string `json:"context,omitempty" jsonschema:"Optional annotation context used to identify or append to an annotation"`
	Append       bool   `json:"append,omitempty" jsonschema:"Append the body to an existing annotation with the same context"`
}

type DeleteAnnotationArgs struct {
	OrgSlug      string `json:"org_slug"`
	PipelineSlug string `json:"pipeline_slug"`
	BuildNumber  string `json:"build_number"`
	AnnotationID string `json:"annotation_id"`
}

type ListJobAnnotationsArgs struct {
	OrgSlug      string `json:"org_slug"`
	PipelineSlug string `json:"pipeline_slug"`
	BuildNumber  string `json:"build_number"`
	JobID        string `json:"job_id"`
	Page         int    `json:"page,omitempty" jsonschema:"Page number for pagination (min 1)"`
	PerPage      int    `json:"per_page,omitempty" jsonschema:"Results per page for pagination (min 1\\, max 100)"`
}

type CreateJobAnnotationArgs struct {
	OrgSlug      string `json:"org_slug"`
	PipelineSlug string `json:"pipeline_slug"`
	BuildNumber  string `json:"build_number"`
	JobID        string `json:"job_id"`
	Body         string `json:"body" jsonschema:"The annotation body as HTML or Markdown"`
	Style        string `json:"style,omitempty" jsonschema:"Optional annotation style: success, info, warning, or error"`
	Priority     int    `json:"priority,omitempty" jsonschema:"Optional annotation priority from 1 to 10"`
	Context      string `json:"context,omitempty" jsonschema:"Optional annotation context used to identify or append to an annotation"`
	Append       bool   `json:"append,omitempty" jsonschema:"Append the body to an existing annotation with the same context"`
}

type DeleteJobAnnotationArgs struct {
	OrgSlug      string `json:"org_slug"`
	PipelineSlug string `json:"pipeline_slug"`
	BuildNumber  string `json:"build_number"`
	JobID        string `json:"job_id"`
	AnnotationID string `json:"annotation_id"`
}

// ListAnnotations returns an MCP tool + handler pair that lists annotations for a build.
func ListAnnotations() (mcp.Tool, mcp.ToolHandlerFor[ListAnnotationsArgs, any], []string) {
	return mcp.Tool{
			Name:        "list_annotations",
			Description: "List all annotations for a build, including their context, scope, style, rendered HTML content, and timestamps",
			Annotations: &mcp.ToolAnnotations{
				Title:        "List Build Annotations",
				ReadOnlyHint: true,
			},
		}, func(ctx context.Context, request *mcp.CallToolRequest, args ListAnnotationsArgs) (*mcp.CallToolResult, any, error) {
			ctx, span := trace.Start(ctx, "buildkite.ListAnnotations")
			defer span.End()

			paginationParams := paginationFromArgs(args.Page, args.PerPage)

			span.SetAttributes(
				attribute.String("org_slug", args.OrgSlug),
				attribute.String("pipeline_slug", args.PipelineSlug),
				attribute.String("build_number", args.BuildNumber),
				attribute.Int("page", paginationParams.Page),
				attribute.Int("per_page", paginationParams.PerPage),
			)

			deps := DepsFromContext(ctx)
			annotations, resp, err := deps.AnnotationsClient.ListByBuild(ctx, args.OrgSlug, args.PipelineSlug, args.BuildNumber, &buildkite.AnnotationListOptions{
				ListOptions: paginationParams,
			})
			if err != nil {
				return handleBuildkiteError(err)
			}

			result := PaginatedResult[buildkite.Annotation]{
				Items: annotations,
				Headers: map[string]string{
					"Link": resp.Header.Get("Link"),
				},
			}

			span.SetAttributes(
				attribute.Int("item_count", len(annotations)),
			)

			return mcpTextResult(span, &result)
		}, []string{"read_builds"}
}

func CreateAnnotation() (mcp.Tool, mcp.ToolHandlerFor[CreateAnnotationArgs, any], []string) {
	return mcp.Tool{
			Name:        "create_annotation",
			Description: "Create a build-level annotation on a Buildkite build using HTML or Markdown content",
			Annotations: &mcp.ToolAnnotations{
				Title: "Create Build Annotation",
			},
		}, func(ctx context.Context, request *mcp.CallToolRequest, args CreateAnnotationArgs) (*mcp.CallToolResult, any, error) {
			ctx, span := trace.Start(ctx, "buildkite.CreateAnnotation")
			defer span.End()

			span.SetAttributes(
				attribute.String("org_slug", args.OrgSlug),
				attribute.String("pipeline_slug", args.PipelineSlug),
				attribute.String("build_number", args.BuildNumber),
				attribute.String("context", args.Context),
				attribute.String("style", args.Style),
				attribute.Int("priority", args.Priority),
				attribute.Bool("append", args.Append),
			)

			deps := DepsFromContext(ctx)
			annotation, _, err := deps.AnnotationsClient.Create(ctx, args.OrgSlug, args.PipelineSlug, args.BuildNumber, buildkite.AnnotationCreate{
				Body:     args.Body,
				Context:  args.Context,
				Style:    args.Style,
				Priority: args.Priority,
				Append:   args.Append,
			})
			if err != nil {
				return handleBuildkiteError(err)
			}

			return mcpTextResult(span, &annotation)
		}, []string{"write_builds"}
}

func DeleteAnnotation() (mcp.Tool, mcp.ToolHandlerFor[DeleteAnnotationArgs, any], []string) {
	return mcp.Tool{
			Name:        "delete_annotation",
			Description: "Delete a build-level annotation from a Buildkite build",
			Annotations: &mcp.ToolAnnotations{
				Title:           "Delete Build Annotation",
				DestructiveHint: boolPtr(true),
			},
		}, func(ctx context.Context, request *mcp.CallToolRequest, args DeleteAnnotationArgs) (*mcp.CallToolResult, any, error) {
			ctx, span := trace.Start(ctx, "buildkite.DeleteAnnotation")
			defer span.End()

			span.SetAttributes(
				attribute.String("org_slug", args.OrgSlug),
				attribute.String("pipeline_slug", args.PipelineSlug),
				attribute.String("build_number", args.BuildNumber),
				attribute.String("annotation_id", args.AnnotationID),
			)

			deps := DepsFromContext(ctx)
			_, err := deps.AnnotationsClient.Delete(ctx, args.OrgSlug, args.PipelineSlug, args.BuildNumber, args.AnnotationID)
			if err != nil {
				return handleBuildkiteError(err)
			}

			return mcpTextResult(span, map[string]any{
				"deleted":       true,
				"scope":         "build",
				"annotation_id": args.AnnotationID,
			})
		}, []string{"write_builds"}
}

func ListJobAnnotations() (mcp.Tool, mcp.ToolHandlerFor[ListJobAnnotationsArgs, any], []string) {
	return mcp.Tool{
			Name:        "list_job_annotations",
			Description: "List all annotations for a specific job, including their context, scope, style, rendered HTML content, and timestamps",
			Annotations: &mcp.ToolAnnotations{
				Title:        "List Job Annotations",
				ReadOnlyHint: true,
			},
		}, func(ctx context.Context, request *mcp.CallToolRequest, args ListJobAnnotationsArgs) (*mcp.CallToolResult, any, error) {
			ctx, span := trace.Start(ctx, "buildkite.ListJobAnnotations")
			defer span.End()

			paginationParams := paginationFromArgs(args.Page, args.PerPage)

			span.SetAttributes(
				attribute.String("org_slug", args.OrgSlug),
				attribute.String("pipeline_slug", args.PipelineSlug),
				attribute.String("build_number", args.BuildNumber),
				attribute.String("job_id", args.JobID),
				attribute.Int("page", paginationParams.Page),
				attribute.Int("per_page", paginationParams.PerPage),
			)

			deps := DepsFromContext(ctx)
			annotations, resp, err := deps.AnnotationsClient.ListByJob(ctx, args.OrgSlug, args.PipelineSlug, args.BuildNumber, args.JobID, &buildkite.AnnotationListOptions{
				ListOptions: paginationParams,
			})
			if err != nil {
				return handleBuildkiteError(err)
			}

			result := PaginatedResult[buildkite.Annotation]{
				Items: annotations,
				Headers: map[string]string{
					"Link": resp.Header.Get("Link"),
				},
			}

			span.SetAttributes(
				attribute.Int("item_count", len(annotations)),
			)

			return mcpTextResult(span, &result)
		}, []string{"read_builds"}
}

func CreateJobAnnotation() (mcp.Tool, mcp.ToolHandlerFor[CreateJobAnnotationArgs, any], []string) {
	return mcp.Tool{
			Name:        "create_job_annotation",
			Description: "Create a job-level annotation on a specific Buildkite job using HTML or Markdown content",
			Annotations: &mcp.ToolAnnotations{
				Title: "Create Job Annotation",
			},
		}, func(ctx context.Context, request *mcp.CallToolRequest, args CreateJobAnnotationArgs) (*mcp.CallToolResult, any, error) {
			ctx, span := trace.Start(ctx, "buildkite.CreateJobAnnotation")
			defer span.End()

			span.SetAttributes(
				attribute.String("org_slug", args.OrgSlug),
				attribute.String("pipeline_slug", args.PipelineSlug),
				attribute.String("build_number", args.BuildNumber),
				attribute.String("job_id", args.JobID),
				attribute.String("context", args.Context),
				attribute.String("style", args.Style),
				attribute.Int("priority", args.Priority),
				attribute.Bool("append", args.Append),
			)

			deps := DepsFromContext(ctx)
			annotation, _, err := deps.AnnotationsClient.CreateForJob(ctx, args.OrgSlug, args.PipelineSlug, args.BuildNumber, args.JobID, buildkite.AnnotationCreate{
				Body:     args.Body,
				Context:  args.Context,
				Style:    args.Style,
				Priority: args.Priority,
				Append:   args.Append,
			})
			if err != nil {
				return handleBuildkiteError(err)
			}

			return mcpTextResult(span, &annotation)
		}, []string{"write_builds"}
}

func DeleteJobAnnotation() (mcp.Tool, mcp.ToolHandlerFor[DeleteJobAnnotationArgs, any], []string) {
	return mcp.Tool{
			Name:        "delete_job_annotation",
			Description: "Delete a job-level annotation from a specific job in a Buildkite build",
			Annotations: &mcp.ToolAnnotations{
				Title:           "Delete Job Annotation",
				DestructiveHint: boolPtr(true),
			},
		}, func(ctx context.Context, request *mcp.CallToolRequest, args DeleteJobAnnotationArgs) (*mcp.CallToolResult, any, error) {
			ctx, span := trace.Start(ctx, "buildkite.DeleteJobAnnotation")
			defer span.End()

			span.SetAttributes(
				attribute.String("org_slug", args.OrgSlug),
				attribute.String("pipeline_slug", args.PipelineSlug),
				attribute.String("build_number", args.BuildNumber),
				attribute.String("job_id", args.JobID),
				attribute.String("annotation_id", args.AnnotationID),
			)

			deps := DepsFromContext(ctx)
			_, err := deps.AnnotationsClient.DeleteForJob(ctx, args.OrgSlug, args.PipelineSlug, args.BuildNumber, args.JobID, args.AnnotationID)
			if err != nil {
				return handleBuildkiteError(err)
			}

			return mcpTextResult(span, map[string]any{
				"deleted":       true,
				"scope":         "job",
				"job_id":        args.JobID,
				"annotation_id": args.AnnotationID,
			})
		}, []string{"write_builds"}
}
