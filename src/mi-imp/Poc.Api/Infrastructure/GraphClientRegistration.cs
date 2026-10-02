using Azure.Core;
using Azure.Identity;
using Microsoft.Graph;

namespace Poc.Api.Infrastructure;

public static class GraphClientRegistration
{
    /// <summary>
    /// Registers an app-only <see cref="GraphServiceClient"/> that authenticates as the API's managed identity.
    /// <c>ManagedIdentity:ClientId</c> selects a user-assigned identity; omit it for system-assigned.
    /// </summary>
    public static IServiceCollection AddManagedIdentityGraphClient(
        this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
    {
        var baseUrl = configuration["MicrosoftGraph:BaseUrl"] ?? "https://graph.microsoft.com/v1.0";
        // App-only tokens use the resource's .default scope, which follows the cloud (graph.microsoft.us in Gov).
        var scope = $"{new Uri(baseUrl).GetLeftPart(UriPartial.Authority)}/.default";

        services.AddSingleton(new GraphServiceClient(CreateCredential(configuration, environment), [scope], baseUrl));
        return services;
    }

    private static TokenCredential CreateCredential(IConfiguration configuration, IHostEnvironment environment)
    {
        // No managed identity exists on a dev machine, so local runs call Graph as the `az login` user instead.
        if (environment.IsDevelopment())
        {
            return new AzureCliCredential(new AzureCliCredentialOptions { TenantId = configuration["AzureAd:TenantId"] });
        }

        var clientId = configuration["ManagedIdentity:ClientId"];
        return new ManagedIdentityCredential(string.IsNullOrWhiteSpace(clientId)
            ? ManagedIdentityId.SystemAssigned
            : ManagedIdentityId.FromUserAssignedClientId(clientId));
    }
}
