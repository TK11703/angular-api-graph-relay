using Azure.Identity;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Graph.Models.ODataErrors;

namespace Poc.Api.Infrastructure;

/// <summary>Turns Graph / managed identity failures into ProblemDetails instead of a raw 500.</summary>
public sealed class GraphExceptionHandler(IProblemDetailsService problemDetails, ILogger<GraphExceptionHandler> logger)
    : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        var (status, title, detail) = exception switch
        {
            AuthenticationFailedException => (
                StatusCodes.Status503ServiceUnavailable,
                "Graph token unavailable",
                "The API could not obtain a Microsoft Graph token for its managed identity."),

            ODataError odata => (
                odata.ResponseStatusCode is >= 400 and < 600 ? odata.ResponseStatusCode : StatusCodes.Status502BadGateway,
                "Microsoft Graph request failed",
                odata.Error?.Message ?? "Microsoft Graph rejected the request."),

            _ => (0, string.Empty, string.Empty)
        };

        if (status == 0)
        {
            return false;
        }

        logger.LogWarning(exception, "Graph call failed with status {Status}", status);
        httpContext.Response.StatusCode = status;

        return await problemDetails.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = httpContext,
            ProblemDetails = new ProblemDetails
            {
                Status = status,
                Title = title,
                Detail = detail
            }
        });
    }
}
