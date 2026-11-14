import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, RouterProvider } from "react-router";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TenantProvider } from "./tenant";
import { Layout } from "./Layout";
import { Home } from "./pages/Home";
import { AvailabilityPage } from "./pages/availability/AvailabilityPage";
import "./styles.css";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
});

const router = createBrowserRouter([
  {
    element: <Layout />,
    children: [
      { path: "/", element: <Home /> },
      { path: "/availability", element: <AvailabilityPage /> },
      { path: "*", element: <p>Page not found.</p> },
    ],
  },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <TenantProvider>
        <RouterProvider router={router} />
      </TenantProvider>
    </QueryClientProvider>
  </StrictMode>,
);
