import { render, screen } from "@testing-library/react-native";
import App from "../src/App";

test("renders the root placeholder", async () => {
  await render(<App />);
  expect(screen.getByTestId("app-root")).toHaveTextContent(/^aiur$/);
});
