import type { Metadata } from "next";
import "./globals.css";
export const metadata:Metadata={title:"Retail Sales and Inventory",description:"A simple point-of-sale and inventory workspace for growing retail stores.",icons:{icon:"/favicon.svg",shortcut:"/favicon.svg"}};
export default function RootLayout({children}:Readonly<{children:React.ReactNode}>){return <html lang="en"><body>{children}</body></html>}
