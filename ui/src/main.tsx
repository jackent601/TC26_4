import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, RouterProvider } from "react-router";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TenantProvider } from "./tenant";
import { UserProvider } from "./user";
import { ThemeProvider } from "./theme";
import { Layout } from "./Layout";
import { Home } from "./pages/Home";
import { AvailabilityPage } from "./pages/availability/AvailabilityPage";
import { OverviewPage } from "./pages/overview/OverviewPage";
import "./styles.css";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

const router = createBrowserRouter([
  {
    element: <Layout />,
    children: [
      { path: "/", element: <Home /> },
      { path: "/overview", element: <OverviewPage /> },
      { path: "/availability", element: <AvailabilityPage /> },
      { path: "*", element: <p>Page not found.</p> },
    ],
  },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <ThemeProvider>
        <UserProvider>
          <TenantProvider>
            <RouterProvider router={router} />
          </TenantProvider>
        </UserProvider>
      </ThemeProvider>
    </QueryClientProvider>
  </StrictMode>,
);
